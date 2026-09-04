[CmdletBinding()]
param(
    [string]$DistroName = "openhands-worker",
    [string]$ImagePath,
    [string]$ImageUri,
    [string]$ImageSha256
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Set-WslMirroredNetworking {
    param([Parameter(Mandatory)][string]$Path)

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $original = if ($exists) { [System.IO.File]::ReadAllText($Path) } else { "" }
    $newline = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hasTrailingNewline = $original.EndsWith("`n")
    $lines = New-Object 'System.Collections.Generic.List[string]'
    if ($original.Length) {
        $lines.AddRange([string[]]($original -split "`r?`n"))
        if ($lines[$lines.Count - 1] -eq "") {
            $lines.RemoveAt($lines.Count - 1)
        }
    }

    $sections = @{}
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
            $name = $Matches[1].Trim()
            if ($sections.ContainsKey($name)) {
                throw "Duplicate section [$name] in '$Path'."
            }
            $sections[$name] = $index
        }
    }

    $wsl2Name = $sections.Keys | Where-Object { $_ -ieq "wsl2" } | Select-Object -First 1
    if ($null -eq $wsl2Name) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne "") {
            $lines.Add("")
        }
        $lines.Add("[wsl2]")
        $lines.Add("networkingMode=mirrored")
        $lines.Add("dnsTunneling=true")
    }
    else {
        $sectionIndex = [int]$sections[$wsl2Name]
        $start = $sectionIndex + 1
        $end = $lines.Count
        foreach ($sectionStart in $sections.Values) {
            if ($sectionStart -gt $sectionIndex -and $sectionStart -lt $end) {
                $end = $sectionStart
            }
        }

        $keys = @{}
        for ($index = $start; $index -lt $end; $index++) {
            if ($lines[$index] -match '^\s*([^=;#\s][^=]*)=') {
                $key = $Matches[1].Trim()
                if ($keys.ContainsKey($key)) {
                    throw "Duplicate key '$key' in [wsl2] in '$Path'."
                }
                $keys[$key] = $index
            }
        }

        $networkingKey = $keys.Keys | Where-Object { $_ -ieq "networkingMode" } | Select-Object -First 1
        $dnsKey = $keys.Keys | Where-Object { $_ -ieq "dnsTunneling" } | Select-Object -First 1
        if ($null -ne $networkingKey -and $null -ne $dnsKey -and
            $lines[[int]$keys[$networkingKey]] -match ("^\s*" + [regex]::Escape($networkingKey) + "\s*=\s*mirrored\s*(?:[;#].*)?$") -and
            $lines[[int]$keys[$dnsKey]] -match ("^\s*" + [regex]::Escape($dnsKey) + "\s*=\s*true\s*(?:[;#].*)?$") ) {
            return [pscustomobject]@{ Changed = $false; BackupPath = $null }
        }

        foreach ($setting in @(@("networkingMode", "mirrored"), @("dnsTunneling", "true"))) {
            $key = $setting[0]
            $value = $setting[1]
            $keyName = $keys.Keys | Where-Object { $_ -ieq $key } | Select-Object -First 1
            if ($null -eq $keyName) {
                $lines.Insert($end, "$key=$value")
                $end++
            }
            elseif ($lines[[int]$keys[$keyName]] -notmatch ("^\s*" + [regex]::Escape($keyName) + "\s*=\s*" + [regex]::Escape($value) + "\s*(?:[;#].*)?$") ) {
                $line = $lines[[int]$keys[$keyName]]
                if ($line -notmatch ("^(?<prefix>\s*" + [regex]::Escape($keyName) + "\s*=\s*)[^\s;#]*(?<suffix>\s*(?:[;#].*)?)$")) {
                    throw "Unable to update '$keyName' in '$Path'."
                }
                $lines[[int]$keys[$keyName]] = "$($Matches.prefix)$value$($Matches.suffix)"
            }
        }
    }

    $updated = ($lines -join $newline) + $(if (-not $original.Length -or $hasTrailingNewline) { $newline } else { "" })
    if ($updated -eq $original) {
        return [pscustomobject]@{ Changed = $false; BackupPath = $null }
    }

    $directory = Split-Path -Parent $Path
    if (-not $directory) {
        $directory = "."
    }
    $leaf = Split-Path -Leaf $Path
    $backupPath = $null
    if ($exists) {
        $backupPath = Join-Path $directory ("$leaf." + (Get-Date -Format "yyyyMMddHHmmssfff") + ".bak")
    }

    $temporaryPath = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $updated, $encoding)
        if ($exists) {
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    return [pscustomobject]@{ Changed = $true; BackupPath = $backupPath }
}


function Test-WslDistributionRegistered {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory)][string]$Name
    )

    return [bool]((($Output -replace [string][char]0, "") -join "`n") -match ("(?m)^\s*" + [regex]::Escape($Name) + "\s*$"))
}

function Test-UbuntuRelease {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory)][string]$Version
    )

    $normalized = ($Output -replace [string][char]0, "") -join "`n"
    $ids = [regex]::Matches($normalized, '(?m)^ID=(?<value>.*?)(?:\r)?$')
    $versions = [regex]::Matches($normalized, '(?m)^VERSION_ID=(?<value>.*?)(?:\r)?$')
    if ($ids.Count -ne 1 -or $versions.Count -ne 1) {
        return $false
    }

    $id = $ids[0].Groups["value"].Value
    $releaseVersion = $versions[0].Groups["value"].Value
    return [bool](($id -ceq "ubuntu" -or $id -ceq '"ubuntu"') -and ($releaseVersion -ceq $Version -or $releaseVersion -ceq ('"' + $Version + '"')))
}

function Assert-WslDistributionIdentity {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Name
    )

    $failure = $null
    $terminationFailure = $null
    try {
        $uid = & $WslPath --distribution $Name --user root --exec id -u
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to verify root access for WSL distribution '$Name'."
        }
        if ((($uid -replace [string][char]0, "") -join "`n").Trim() -ne "0") {
            throw "WSL distribution '$Name' did not run as root."
        }

        $release = & $WslPath --distribution $Name --user root --exec cat /etc/os-release
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read the release identity for WSL distribution '$Name'."
        }
        if (-not (Test-UbuntuRelease -Output $release -Version "26.04")) {
            throw "WSL distribution '$Name' is not Ubuntu 26.04."
        }
    }
    catch {
        $failure = $_
    }
    finally {
        try {
            & $WslPath --terminate $Name
            if ($LASTEXITCODE -ne 0) {
                $terminationFailure = "Unable to terminate WSL distribution '$Name'."
            }
        }
        catch {
            $terminationFailure = $_.Exception.Message
        }
    }

    if ($failure -and $terminationFailure) {
        throw "$($failure.Exception.Message) $terminationFailure"
    }
    if ($failure) {
        throw $failure
    }
    if ($terminationFailure) {
        throw $terminationFailure
    }
}

function Get-WslArtifactArchitecture {
    param(
        [string]$Architecture = $env:PROCESSOR_ARCHITECTURE,
        [string]$Wow64Architecture = $env:PROCESSOR_ARCHITEW6432,
        [string]$RuntimeArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    )

    $detectedArchitecture = if (-not [string]::IsNullOrWhiteSpace($Wow64Architecture)) { $Wow64Architecture } elseif (-not [string]::IsNullOrWhiteSpace($Architecture)) { $Architecture } else { $RuntimeArchitecture }
    switch ($detectedArchitecture.ToUpperInvariant()) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        default { throw "Unsupported Windows architecture '$Architecture'." }
    }
}

function Get-WslImageSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Stream))).Replace("-", "")
    }
    finally {
        $sha256.Dispose()
    }
}

function Resolve-WslImage {
    param(
        [string]$ImagePath,
        [string]$ImageUri,
        [Parameter(Mandatory)][string]$ImageSha256,
        [Parameter(Mandatory)][string]$Architecture
    )

    $hasPath = -not [string]::IsNullOrWhiteSpace($ImagePath)
    $hasUri = -not [string]::IsNullOrWhiteSpace($ImageUri)
    if ($hasPath -eq $hasUri) {
        throw "Specify exactly one of ImagePath or ImageUri."
    }
    if ($ImageSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "ImageSha256 must be a 64-character hexadecimal SHA-256 value."
    }

    $artifactArchitecture = Get-WslArtifactArchitecture -Architecture $Architecture
    if ($hasUri) {
        $uri = $null
        if (-not [Uri]::TryCreate($ImageUri, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne "https") {
            throw "ImageUri must be an absolute HTTPS URI."
        }
        $leaf = [IO.Path]::GetFileName($uri.AbsolutePath)
    }
    else {
        $source = Get-Item -LiteralPath $ImagePath -Force -ErrorAction Stop
        if (-not ($source -is [IO.FileInfo]) -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "ImagePath '$ImagePath' must be a non-reparse regular file."
        }
        $leaf = $source.Name
    }

    if ($leaf -notmatch ("-" + [regex]::Escape($artifactArchitecture) + '\.wsl$')) {
        throw "WSL image '$leaf' does not match architecture '$artifactArchitecture'."
    }

    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ("openhands-worker-" + [Guid]::NewGuid().ToString("N"))
    $resolvedPath = Join-Path $temporaryDirectory $leaf
    $stream = $null
    try {
        New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
        if ($hasUri) {
            Invoke-WebRequest -Uri $uri -OutFile $resolvedPath -UseBasicParsing
        }
        else {
            [IO.File]::Copy($source.FullName, $resolvedPath, $false)
        }

        $staged = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
        if (-not ($staged -is [IO.FileInfo]) -or ($staged.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $staged.Name -cne $leaf) {
            throw "Staged WSL image '$resolvedPath' must be a regular file."
        }
        $stream = [IO.File]::Open($staged.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $actualHash = Get-WslImageSha256 -Stream $stream
        if ($actualHash -ine $ImageSha256) {
            throw "WSL image SHA-256 does not match ImageSha256."
        }

        $image = [pscustomobject]@{ Path = $staged.FullName; TemporaryDirectory = $temporaryDirectory; Stream = $stream }
        $image | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Stream.Dispose() }
        return $image
    }
    catch {
        if ($stream) {
            $stream.Dispose()
        }
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Install-WslDistribution {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Name,
        [string]$ImagePath,
        [string]$ImageUri,
        [string]$ImageSha256,
        [string]$Architecture = $env:PROCESSOR_ARCHITECTURE
    )

    $registered = & $WslPath --list --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list installed WSL distributions."
    }
    if (Test-WslDistributionRegistered -Output $registered -Name $Name) {
        Write-Host "WSL distribution '$Name' already exists."
        return $false
    }

    $image = Resolve-WslImage -ImagePath $ImagePath -ImageUri $ImageUri -ImageSha256 $ImageSha256 -Architecture $Architecture
    try {
        & $WslPath --install --from-file $image.Path --name $Name --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to import WSL distribution '$Name'."
        }

        $registered = & $WslPath --list --quiet
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to verify WSL distribution registration."
        }
        if (-not (Test-WslDistributionRegistered -Output $registered -Name $Name)) {
            throw "WSL distribution '$Name' was not registered."
        }
    }
    finally {
        if ($image) {
            $image.Dispose()
        }
        if ($image.TemporaryDirectory) {
            Remove-Item -LiteralPath $image.TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $true
}

function Get-WslExecutablePath {
    param(
        [string]$WindowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        [bool]$Is64BitProcess = [Environment]::Is64BitProcess,
        [bool]$Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
    )

    if ([string]::IsNullOrWhiteSpace($WindowsDirectory)) {
        throw "Unable to locate the Windows directory."
    }

    $directory = if (-not $Is64BitProcess -and $Is64BitOperatingSystem) { "$WindowsDirectory\Sysnative" } else { "$WindowsDirectory\System32" }
    return "$directory\wsl.exe"
}

function Test-WslVersionSupported {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Output)

    $normalized = ($Output -replace [string][char]0, "") -join "`n"
    $match = [regex]::Match($normalized, '(?m)^\s*[^:\r\n]+:\s*(\d+(?:\.\d+){1,3})\s*$')
    if (-not $match.Success) {
        return $false
    }

    try {
        return [version]$match.Groups[1].Value -ge [version]"2.7"
    }
    catch {
        return $false
    }
}

function Restore-WslConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$BackupPath
    )

    if ($BackupPath) {
        $directory = Split-Path -Parent $Path
        if (-not $directory) {
            $directory = "."
        }
        $leaf = Split-Path -Leaf $Path
        $temporaryPath = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
        $replacedPath = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
        try {
            [System.IO.File]::Copy($BackupPath, $temporaryPath, $false)
            [System.IO.File]::Replace($temporaryPath, $Path, $replacedPath)
        }
        finally {
            foreach ($cleanupPath in @($temporaryPath, $replacedPath)) {
                if (Test-Path -LiteralPath $cleanupPath) {
                    Remove-Item -LiteralPath $cleanupPath -Force
                }
            }
        }
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}


function Assert-WslPrerequisites {

    if ($env:OS -ne "Windows_NT") {
        throw "Windows 11 is required."
    }
    $build = [int](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name CurrentBuildNumber).CurrentBuildNumber
    if ($build -lt 22621) {
        throw "Windows build 22621 or later is required."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this installer from an elevated PowerShell session."
    }

    $wslPath = Get-WslExecutablePath
    if (-not (Test-Path -LiteralPath $wslPath -PathType Leaf)) {
        throw "WSL is not installed at '$wslPath'."
    }

    $versionOutput = & $wslPath --version
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read the installed WSL version."
    }
    if (-not (Test-WslVersionSupported -Output $versionOutput)) {
        throw "WSL version 2.7 or later is required."
    }

    return $wslPath
}

$wslPath = Assert-WslPrerequisites

$configPath = Join-Path $env:USERPROFILE ".wslconfig"
$result = Set-WslMirroredNetworking -Path $configPath
if ($result.Changed) {
    & $wslPath --shutdown
    if ($LASTEXITCODE -ne 0) {
        Restore-WslConfig -Path $configPath -BackupPath $result.BackupPath
        throw "WSL configuration changed, but WSL shutdown failed."
    }
}

Write-Host "WSL bootstrap Stage 1 completed."

if (-not (Install-WslDistribution -WslPath $wslPath -Name $DistroName -ImagePath $ImagePath -ImageUri $ImageUri -ImageSha256 $ImageSha256)) {
    return
}
Write-Host "WSL bootstrap Stage 2 completed."

Assert-WslDistributionIdentity -WslPath $wslPath -Name $DistroName
Write-Host "WSL bootstrap Stage 3 completed."
