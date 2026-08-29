$Distribution = "Ubuntu-26.04"
$DistroName = "openhands-worker"
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

function Test-WslDistributionAvailable {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory)][string]$Distribution
    )

    return [bool]((($Output -replace [string][char]0, "") -join "`n") -match ("(?m)^\s*" + [regex]::Escape($Distribution) + "(?:\s|$)"))
}

function Test-WslNamedInstallSupported {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Output)

    return [bool]((($Output -replace [string][char]0, "") -join "`n") -match '(?m)^\s*--name(?:\s|$)')
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
    $idPattern = '(?m)^ID=(?:ubuntu|"ubuntu")\r?$'
    $versionPattern = '(?m)^VERSION_ID=(?:' + [regex]::Escape($Version) + '|"' + [regex]::Escape($Version) + '")\r?$'
    return [bool]([regex]::Matches($normalized, $idPattern).Count -eq 1 -and [regex]::Matches($normalized, $versionPattern).Count -eq 1)
}

function Assert-WslDistributionIdentity {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Name
    )

    $failure = $null
    $terminateExit = 0
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
        & $WslPath --terminate $Name
        $terminateExit = $LASTEXITCODE
    }

    if ($failure) {
        throw $failure
    }
    if ($terminateExit -ne 0) {
        throw "Unable to terminate WSL distribution '$Name'."
    }
}

function Install-WslDistribution {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Distribution,
        [Parameter(Mandatory)][string]$Name
    )

    $registered = & $WslPath --list --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list installed WSL distributions."
    }
    if (Test-WslDistributionRegistered -Output $registered -Name $Name) {
        Write-Host "WSL distribution '$Name' already exists."
        return $false
    }

    $help = & $WslPath --help
    if (-not (Test-WslNamedInstallSupported -Output $help)) {
        throw "Installed WSL does not support named distribution installation."
    }

    & $WslPath --install --distribution $Distribution --name $Name --no-launch
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to install WSL distribution '$Name'."
    }

    $registered = & $WslPath --list --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to verify WSL distribution registration."
    }
    if (-not (Test-WslDistributionRegistered -Output $registered -Name $Name)) {
        throw "WSL distribution '$Name' was not registered."
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
    param([Parameter(Mandatory)][string]$Distribution)

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

    $online = & $wslPath --list --online
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list online WSL distributions."
    }
    if (-not (Test-WslDistributionAvailable -Output $online -Distribution $Distribution)) {
        throw "Required online WSL distribution '$Distribution' is unavailable."
    }

    return $wslPath
}

$wslPath = Assert-WslPrerequisites -Distribution $Distribution

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

Install-WslDistribution -WslPath $wslPath -Distribution $Distribution -Name $DistroName | Out-Null
Write-Host "WSL bootstrap Stage 2 completed."

Assert-WslDistributionIdentity -WslPath $wslPath -Name $DistroName
Write-Host "WSL bootstrap Stage 3 completed."
