[CmdletBinding()]
param(
    [string]$HostProfile,
    [string]$ProfilePath,
    [string]$ReleaseTag,
    [string]$ChecksumsSha256,
    [string]$DistroName,
    [string]$UbuntuDistribution,
    [string]$Location,
    [string]$OverlayPath,
    [string]$OverlayUri,
    [string]$OverlaySha256,
    [string]$FirewallPath,
    [string]$FirewallUri,
    [string]$FirewallSha256,
    [string]$KeepalivePath,
    [string]$KeepaliveUri,
    [string]$KeepaliveSha256,
    [string]$RootfsPath,
    [string]$RootfsUri,
    [string]$RootfsSha256,
    [switch]$SkipFirewall,
    [switch]$SkipKeepalive
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$DefaultRelease = "coder-worker-v2.0.0"
$DefaultChecksumsSha256 = "3a3faa5b7441f0661888ae9c32a1a83d246b813af59cdf5ee17749b355ba97bf"
$ReleaseBaseUri = "https://github.com/lkshrk/auto-code-env/releases/download"
$StageRoot = "/root/coder-worker"
$TlsPort = 2376
$FirewallRuleName = "coder-worker-docker"
$FirewallRuleDisplayName = "Coder worker Docker"

# Duplicated from worker/windows/install.ps1: both installers ship as standalone release assets.
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

function Test-DistributionName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    return [bool]($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')
}

function Test-ProfileKeySecretShaped {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Key)

    if ($Key -cmatch '^VAULT_ITEM_') {
        return $false
    }
    return [bool]($Key -cmatch 'PASSWORD|PASSWD|SECRET|TOKEN|CREDENTIAL|PRIVATE|PASSPHRASE|APIKEY|^KEY_|_KEY$|_KEY_')
}

function Test-ProfileValueSecretShaped {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ($Value -cmatch '-----BEGIN' -or $Value -cmatch '^(ghp_|github_pat_|sk-)') {
        return $true
    }
    return [bool]($Value -cmatch '[A-Za-z0-9+/=_-]{40,}')
}

function Test-ProfileValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [int]$Port = 2376
    )

    switch -CaseSensitive ($Key) {
        { $_ -cin @("DISTRO_NAME", "UBUNTU_DISTRIBUTION") } { return [bool]($Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') }
        "VHD_LOCATION" { return [bool]($Value -cmatch '^[A-Za-z]:\\[^"<>|*?]{0,200}$') }
        "VAULT_URL" { return [bool]($Value -cmatch '^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$') }
        "VAULT_EMAIL" { return [bool]($Value -cmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') }
        { $_ -ceq "VAULT_FOLDER" -or $_ -cmatch '^VAULT_ITEM_' } { return [bool]($Value -cmatch '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$') }
        "DOCKER_PORT" { return [bool]($Value -ceq "$Port") }
        "FIREWALL_REMOTE_ADDRESSES" {
            $octet = '(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
            $address = "$octet(\.$octet){3}(/([0-9]|[1-2][0-9]|3[0-2]))?"
            return [bool]($Value -cmatch "^$address(,$address)*$")
        }
    }
    return $false
}

function Read-CoderWorkerProfile {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $known = @(
        "DISTRO_NAME", "UBUNTU_DISTRIBUTION", "VHD_LOCATION",
        "VAULT_URL", "VAULT_EMAIL", "VAULT_FOLDER",
        "VAULT_ITEM_CA", "VAULT_ITEM_SERVER_CERT", "VAULT_ITEM_SERVER_KEY",
        "VAULT_ITEM_LAN_CA", "VAULT_ITEM_WORKSPACE_ENV",
        "DOCKER_PORT", "FIREWALL_REMOTE_ADDRESSES"
    )
    $required = @(
        "DISTRO_NAME", "UBUNTU_DISTRIBUTION", "VAULT_URL", "VAULT_EMAIL",
        "VAULT_ITEM_CA", "VAULT_ITEM_SERVER_CERT", "VAULT_ITEM_SERVER_KEY",
        "DOCKER_PORT", "FIREWALL_REMOTE_ADDRESSES"
    )
    $profileValues = @{}
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $number = $index + 1
        $line = $Lines[$index] -replace "`r$", ""
        if ($line -eq "" -or $line.StartsWith("#")) {
            continue
        }
        if ($line -notmatch '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            throw "Profile line ${number} is not NAME=value."
        }
        $key = $Matches[1]
        $value = $Matches[2]
        if (Test-ProfileKeySecretShaped -Key $key) {
            throw "Profile line ${number} names a secret; the profile carries no credentials."
        }
        if ($known -cnotcontains $key) {
            throw "Profile line ${number} has unknown key ${key}."
        }
        if ($profileValues.ContainsKey($key)) {
            throw "Profile line ${number} repeats ${key}."
        }
        if (Test-ProfileValueSecretShaped -Value $value) {
            throw "Profile line ${number} looks like a credential; the profile carries no credentials."
        }
        if (-not (Test-ProfileValue -Key $key -Value $value)) {
            throw "Profile line ${number} has an invalid value for ${key}."
        }
        $profileValues[$key] = $value
    }
    foreach ($key in $required) {
        if (-not $profileValues.ContainsKey($key)) {
            throw "Profile is missing ${key}."
        }
    }
    return $profileValues
}

function Get-ChecksumMap {
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $map = @{}
    foreach ($raw in $Lines) {
        $line = $raw -replace "`r$", ""
        if ($line -eq "") {
            continue
        }
        if ($line -notmatch '^(?<digest>[0-9A-Fa-f]{64})[ ][ *](?<name>[^\\/]+)$') {
            throw "'$line' is not a sha256sum line."
        }
        $name = $Matches["name"]
        if ($name -eq "." -or $name -eq ".." -or $map.ContainsKey($name)) {
            throw "checksums.txt names '$name' more than once or unsafely."
        }
        $map[$name] = $Matches["digest"].ToLowerInvariant()
    }
    if ($map.Count -eq 0) {
        throw "checksums.txt is empty."
    }
    return $map
}

function Get-ReleaseAssetUri {
    param(
        [Parameter(Mandatory)][string]$BaseUri,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Asset
    )

    if ($Tag -cnotmatch '^coder-worker-v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$') {
        throw "Release tag '$Tag' is not a coder-worker release tag."
    }
    if ($Asset -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Release asset name '$Asset' is not valid."
    }
    return "$BaseUri/$Tag/$Asset"
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

function Test-Sha256Digest {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory)][string]$Expected
    )

    $normalized = (($Output -replace [string][char]0, "") -join "`n").Trim()
    $match = [regex]::Match($normalized, '(?m)^(?<digest>[0-9A-Fa-f]{64})\s')
    if (-not $match.Success) {
        return $false
    }
    return [bool]($match.Groups["digest"].Value -ieq $Expected)
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][IO.Stream]$Stream)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Stream))).Replace("-", "")
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-StagedArtifact {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Path,
        [string]$Uri,
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Sha256,
        [Parameter(Mandatory)][string]$Destination
    )

    $hasPath = -not [string]::IsNullOrWhiteSpace($Path)
    $hasUri = -not [string]::IsNullOrWhiteSpace($Uri)
    if ($hasPath -eq $hasUri) {
        throw "Specify exactly one of ${Label}Path or ${Label}Uri."
    }
    if ($Sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
        throw "${Label}Sha256 must be a 64-character hexadecimal SHA-256 value."
    }

    if ($hasUri) {
        $parsed = $null
        if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -cne "https") {
            throw "${Label}Uri must be an absolute HTTPS URI."
        }
        Invoke-WebRequest -Uri $parsed -OutFile $Destination -UseBasicParsing
    }
    else {
        $source = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not ($source -is [IO.FileInfo]) -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "${Label}Path '$Path' must be a non-reparse regular file."
        }
        [IO.File]::Copy($source.FullName, $Destination, $false)
    }

    $staged = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    if (-not ($staged -is [IO.FileInfo]) -or ($staged.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Staged $Label '$Destination' must be a regular file."
    }
    $stream = [IO.File]::Open($staged.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $actual = Get-FileSha256 -Stream $stream
    }
    finally {
        $stream.Dispose()
    }
    if ($actual -ine $Sha256) {
        throw "$Label SHA-256 does not match ${Label}Sha256."
    }

    return $staged.FullName
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

function Get-DistributionInstallArguments {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Flavor,
        [AllowNull()][AllowEmptyString()][string]$Location,
        [AllowNull()][AllowEmptyString()][string]$RootfsPath
    )

    if (-not [string]::IsNullOrWhiteSpace($RootfsPath)) {
        if ([string]::IsNullOrWhiteSpace($Location)) {
            throw "Location is required when installing from a root filesystem."
        }
        return @("--import", $Name, $Location, $RootfsPath, "--version", "2")
    }

    $arguments = @("--install", $Flavor, "--name", $Name, "--no-launch")
    if (-not [string]::IsNullOrWhiteSpace($Location)) {
        $arguments += @("--location", $Location)
    }
    return $arguments
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $output = & $WslPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw $FailureMessage
    }
    return $output
}

function Copy-FileIntoDistribution {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Sha256
    )

    $process = Start-Process -FilePath $WslPath -NoNewWindow -Wait -PassThru `
        -ArgumentList @("--distribution", $Name, "--user", "root", "--exec", "/bin/sh", "-c", "cat > $Target") `
        -RedirectStandardInput $Source
    if ($process.ExitCode -ne 0) {
        throw "Unable to copy '$Source' into WSL distribution '$Name'."
    }

    $digest = & $WslPath --distribution $Name --user root --exec /usr/bin/sha256sum $Target
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to hash '$Target' inside WSL distribution '$Name'."
    }
    if (-not (Test-Sha256Digest -Output $digest -Expected $Sha256)) {
        throw "'$Target' inside WSL distribution '$Name' does not match its expected SHA-256."
    }
}

function Assert-WslDistributionIdentity {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version
    )

    $uid = Invoke-Wsl -WslPath $WslPath -Arguments @("--distribution", $Name, "--user", "root", "--exec", "id", "-u") `
        -FailureMessage "Unable to verify root access for WSL distribution '$Name'."
    if ((($uid -replace [string][char]0, "") -join "`n").Trim() -ne "0") {
        throw "WSL distribution '$Name' did not run as root."
    }

    $release = Invoke-Wsl -WslPath $WslPath -Arguments @("--distribution", $Name, "--user", "root", "--exec", "cat", "/etc/os-release") `
        -FailureMessage "Unable to read the release identity for WSL distribution '$Name'."
    if (-not (Test-UbuntuRelease -Output $release -Version $Version)) {
        throw "WSL distribution '$Name' is not Ubuntu $Version."
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

$stage = Join-Path ([IO.Path]::GetTempPath()) ("coder-worker-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $tag = if ([string]::IsNullOrWhiteSpace($ReleaseTag)) { $DefaultRelease } else { $ReleaseTag }
    $checksums = $null

    function Get-ReleaseChecksums {
        if ($null -ne $script:checksums) {
            return $script:checksums
        }
        $destination = Join-Path $stage "checksums.txt"
        $uri = Get-ReleaseAssetUri -BaseUri $ReleaseBaseUri -Tag $tag -Asset "checksums.txt"
        $parsed = $null
        if (-not [Uri]::TryCreate($uri, [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -cne "https") {
            throw "The release base URI must be absolute HTTPS."
        }
        $expected = $ChecksumsSha256
        if ([string]::IsNullOrWhiteSpace($expected)) {
            if ($tag -cne $DefaultRelease) {
                throw "-ChecksumsSha256 is required with -ReleaseTag; the embedded digest only covers $DefaultRelease."
            }
            $expected = $DefaultChecksumsSha256
        }
        if ($expected -notmatch '^[0-9A-Fa-f]{64}$') {
            throw "ChecksumsSha256 must be a 64-character hexadecimal SHA-256 value."
        }
        Invoke-WebRequest -Uri $parsed -OutFile $destination -UseBasicParsing
        $stream = [IO.File]::Open($destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $actual = Get-FileSha256 -Stream $stream
        }
        finally {
            $stream.Dispose()
        }
        if ($actual -ine $expected) {
            throw "checksums.txt SHA-256 does not match the expected digest."
        }
        $script:checksums = Get-ChecksumMap -Lines ([string[]][IO.File]::ReadAllLines($destination))
        return $script:checksums
    }

    function Get-Artifact {
        param(
            [Parameter(Mandatory)][string]$Label,
            [Parameter(Mandatory)][string]$Asset,
            [AllowEmptyString()][AllowNull()][string]$Path,
            [AllowEmptyString()][AllowNull()][string]$Uri,
            [AllowEmptyString()][AllowNull()][string]$Sha256,
            [Parameter(Mandatory)][string]$Destination
        )

        if ([string]::IsNullOrWhiteSpace($Path) -and [string]::IsNullOrWhiteSpace($Uri)) {
            $map = Get-ReleaseChecksums
            if (-not $map.ContainsKey($Asset)) {
                throw "checksums.txt for '$tag' has no entry for '$Asset'."
            }
            $Uri = Get-ReleaseAssetUri -BaseUri $ReleaseBaseUri -Tag $tag -Asset $Asset
            $Sha256 = $map[$Asset]
        }
        return Get-StagedArtifact -Label $Label -Path $Path -Uri $Uri -Sha256 $Sha256 -Destination $Destination
    }

    if (-not [string]::IsNullOrWhiteSpace($ProfilePath) -and -not [string]::IsNullOrWhiteSpace($HostProfile)) {
        throw "Specify exactly one of -ProfilePath or -HostProfile."
    }
    if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
        if ([string]::IsNullOrWhiteSpace($HostProfile)) {
            throw "Specify -HostProfile <name> (see coder-worker/hosts) or -ProfilePath <file>."
        }
        if (-not (Test-DistributionName -Name $HostProfile)) {
            throw "Host profile name '$HostProfile' is not valid."
        }
        $repositoryProfile = Join-Path $PSScriptRoot (Join-Path ".." (Join-Path "hosts" "$HostProfile.profile"))
        if (Test-Path -LiteralPath $repositoryProfile -PathType Leaf) {
            $ProfilePath = $repositoryProfile
        }
        else {
            $ProfilePath = Get-Artifact -Label "Profile" -Asset "host-$HostProfile.profile" `
                -Destination (Join-Path $stage "downloaded.profile")
        }
    }
    $settings = Read-CoderWorkerProfile -Lines ([string[]][IO.File]::ReadAllLines($ProfilePath))

    if ([string]::IsNullOrWhiteSpace($DistroName)) { $DistroName = $settings["DISTRO_NAME"] }
    if ([string]::IsNullOrWhiteSpace($UbuntuDistribution)) { $UbuntuDistribution = $settings["UBUNTU_DISTRIBUTION"] }
    if ([string]::IsNullOrWhiteSpace($Location) -and $settings.ContainsKey("VHD_LOCATION")) { $Location = $settings["VHD_LOCATION"] }
    $ubuntuVersion = $UbuntuDistribution -replace '^Ubuntu-', ''
    $dockerPort = [int]$settings["DOCKER_PORT"]
    $remoteAddresses = $settings["FIREWALL_REMOTE_ADDRESSES"]

    if (-not (Test-DistributionName -Name $DistroName)) {
        throw "Distribution name '$DistroName' is not valid."
    }
    if (-not (Test-DistributionName -Name $UbuntuDistribution)) {
        throw "Ubuntu distribution name '$UbuntuDistribution' is not valid."
    }
    if ($dockerPort -ne $TlsPort) {
        throw "DOCKER_PORT must be $TlsPort."
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

    if ($SkipFirewall) {
        Write-Host "Skipping the firewall rule: TCP/$dockerPort is not restricted by this run."
    }
    else {
        $firewall = Get-Artifact -Label "Firewall" -Asset "firewall.ps1" -Path $FirewallPath -Uri $FirewallUri `
            -Sha256 $FirewallSha256 -Destination (Join-Path $stage "firewall.ps1")
        & $firewall -RuleName $FirewallRuleName -RuleDisplayName $FirewallRuleDisplayName `
            -Port $dockerPort -RemoteAddresses $remoteAddresses
    }

    $registered = Invoke-Wsl -WslPath $wslPath -Arguments @("--list", "--quiet") `
        -FailureMessage "Unable to list installed WSL distributions."
    $exists = Test-WslDistributionRegistered -Output $registered -Name $DistroName
    if ($exists) {
        Write-Host "WSL distribution '$DistroName' already exists; reconciling it."
    }

    $overlay = Get-Artifact -Label "Overlay" -Asset "coder-worker-overlay" -Path $OverlayPath -Uri $OverlayUri `
        -Sha256 $OverlaySha256 -Destination (Join-Path $stage "coder-worker-overlay")
    $overlayStream = [IO.File]::Open($overlay, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $overlayDigest = Get-FileSha256 -Stream $overlayStream
    }
    finally {
        $overlayStream.Dispose()
    }

    $stagedProfile = Join-Path $stage "profile"
    [IO.File]::Copy((Get-Item -LiteralPath $ProfilePath -Force).FullName, $stagedProfile, $true)
    $profileStream = [IO.File]::Open($stagedProfile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $profileDigest = Get-FileSha256 -Stream $profileStream
    }
    finally {
        $profileStream.Dispose()
    }

    if (-not $exists) {
        $rootfs = $null
        if (-not [string]::IsNullOrWhiteSpace($RootfsPath) -or -not [string]::IsNullOrWhiteSpace($RootfsUri)) {
            $rootfs = Get-StagedArtifact -Label "Rootfs" -Path $RootfsPath -Uri $RootfsUri `
                -Sha256 $RootfsSha256 -Destination (Join-Path $stage "rootfs.tar.gz")
        }

        $installArguments = Get-DistributionInstallArguments -Name $DistroName -Flavor $UbuntuDistribution `
            -Location $Location -RootfsPath $rootfs
        Invoke-Wsl -WslPath $wslPath -Arguments $installArguments `
            -FailureMessage "Unable to install WSL distribution '$DistroName'. If '$UbuntuDistribution' is unavailable on this host, rerun with -RootfsPath or -RootfsUri, -RootfsSha256 and a VHD_LOCATION." | Out-Null

        $registered = Invoke-Wsl -WslPath $wslPath -Arguments @("--list", "--quiet") `
            -FailureMessage "Unable to verify WSL distribution registration."
        if (-not (Test-WslDistributionRegistered -Output $registered -Name $DistroName)) {
            throw "WSL distribution '$DistroName' was not registered."
        }

        Invoke-Wsl -WslPath $wslPath -Arguments @("--manage", $DistroName, "--set-sparse", "true") `
            -FailureMessage "Unable to mark WSL distribution '$DistroName' sparse." | Out-Null
        Write-Host "Coder worker stage 1 completed: '$DistroName' registered."
    }

    Assert-WslDistributionIdentity -WslPath $wslPath -Name $DistroName -Version $ubuntuVersion
    Invoke-Wsl -WslPath $wslPath -Arguments @("--distribution", $DistroName, "--user", "root", "--exec", "/bin/mkdir", "-p", $StageRoot) `
        -FailureMessage "Unable to create '$StageRoot' inside WSL distribution '$DistroName'." | Out-Null
    Copy-FileIntoDistribution -WslPath $wslPath -Name $DistroName -Source $overlay -Target "$StageRoot/coder-worker-overlay" -Sha256 $overlayDigest
    Copy-FileIntoDistribution -WslPath $wslPath -Name $DistroName -Source $stagedProfile -Target "$StageRoot/profile" -Sha256 $profileDigest
    Write-Host "Coder worker stage 2 completed: overlay and host profile staged."

    foreach ($pass in 1, 2) {
        & $wslPath --distribution $DistroName --user root --exec /bin/bash "$StageRoot/coder-worker-overlay" install --profile "$StageRoot/profile"
        if ($LASTEXITCODE -ne 0) {
            throw "Setup pass $pass failed inside WSL distribution '$DistroName'."
        }
        Invoke-Wsl -WslPath $wslPath -Arguments @("--terminate", $DistroName) `
            -FailureMessage "Unable to terminate WSL distribution '$DistroName'." | Out-Null
    }
    Write-Host "Coder worker stage 3 completed: docker installed and held down until TLS material exists."

    if ($SkipKeepalive) {
        Write-Host "Skipping the keepalive task: '$DistroName' will idle-stop between workspace builds."
    }
    else {
        $keepalive = Get-Artifact -Label "Keepalive" -Asset "keepalive.ps1" -Path $KeepalivePath -Uri $KeepaliveUri `
            -Sha256 $KeepaliveSha256 -Destination (Join-Path $stage "keepalive.ps1")
        & $keepalive -DistroName $DistroName -TaskName "$DistroName-keepalive"
    }

    Write-Host "Run: wsl.exe -d $DistroName -u root -- coder-worker-overlay secrets"
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
