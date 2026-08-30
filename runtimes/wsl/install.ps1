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

function Get-WslBootstrapAsset {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Bootstrap asset '$Path' must be a regular file."
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or -not ($item -is [IO.FileInfo])) {
        throw "Bootstrap asset '$Path' must be a non-reparse regular file."
    }

    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    $base64 = [Convert]::ToBase64String($bytes)
    $chunks = New-Object 'System.Collections.Generic.List[string]'
    for ($offset = 0; $offset -lt $base64.Length; $offset += 8192) {
        $length = [Math]::Min(8192, $base64.Length - $offset)
        $chunks.Add($base64.Substring($offset, $length))
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [pscustomobject]@{
            Base64 = $base64
            Chunks = [string[]]$chunks
            Sha256 = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
        }
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-WslShellProgramWrapper {
    return 'program=$(mktemp /tmp/openhands-bootstrap.XXXXXXXXXX); if printf %s $1 | base64 -d >$program && sh $program $2 $3 $4 $5; then result=0; else result=$?; fi; rm -f $program; exit $result'
}

function ConvertTo-WslShellProgramBase64 {
    param([Parameter(Mandatory)][string]$Program)

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    return [Convert]::ToBase64String($encoding.GetBytes(($Program -replace "`r`n?", "`n")))
}

function Get-WslBootstrapTransferInitCommand {
    return @'
set -eu
bootstrap=/root/openhands-bootstrap
asset=$1
case "$asset" in
    provision.sh|wsl.conf) ;;
    *) exit 1 ;;
esac
if [ -e "$bootstrap" ] || [ -L "$bootstrap" ]; then
    [ ! -L "$bootstrap" ] && [ -d "$bootstrap" ] && [ "$(stat -c '%U:%G %a' "$bootstrap")" = 'root:root 700' ] || exit 1
else
    mkdir -m 0700 "$bootstrap"
fi
encoded="$bootstrap/.$asset.base64.tmp"
temporary="$bootstrap/.$asset.decoded.tmp"
for path in "$encoded" "$temporary"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ ! -L "$path" ] && [ -f "$path" ] && [ "$(stat -c '%U:%G %a' "$path")" = 'root:root 600' ] || exit 1
    fi
done
trap 'rm -f "$encoded" "$temporary"' EXIT
rm -f "$encoded" "$temporary"
(umask 077; : > "$encoded")
chown root:root "$encoded"
chmod 600 "$encoded"
trap - EXIT
'@
}

function Get-WslBootstrapTransferChunkCommand {
    return @'
set -eu
bootstrap=/root/openhands-bootstrap
asset=$1
chunk=$2
case "$asset" in
    provision.sh|wsl.conf) ;;
    *) exit 1 ;;
esac
[ ! -L "$bootstrap" ] && [ -d "$bootstrap" ] && [ "$(stat -c '%U:%G %a' "$bootstrap")" = 'root:root 700' ] || exit 1
encoded="$bootstrap/.$asset.base64.tmp"
temporary="$bootstrap/.$asset.decoded.tmp"
[ ! -L "$encoded" ] && [ -f "$encoded" ] && [ "$(stat -c '%U:%G %a' "$encoded")" = 'root:root 600' ] || exit 1
if [ -e "$temporary" ] || [ -L "$temporary" ]; then
    [ ! -L "$temporary" ] && [ -f "$temporary" ] && [ "$(stat -c '%U:%G %a' "$temporary")" = 'root:root 600' ] || exit 1
fi
trap 'rm -f "$encoded" "$temporary"' EXIT
[ "${#chunk}" -le 8192 ] && [ $(( ${#chunk} % 4 )) -eq 0 ] || exit 1
case "$chunk" in
    *[!A-Za-z0-9+/=]*) exit 1 ;;
esac
printf '%s' "$chunk" >> "$encoded"
trap - EXIT
'@
}

function Get-WslBootstrapTransferFinalizeCommand {
    return @'
set -eu
bootstrap=/root/openhands-bootstrap
asset=$1
expected=$2
case "$asset" in
    provision.sh) mode=700 ;;
    wsl.conf) mode=600 ;;
    *) exit 1 ;;
esac
[ ! -L "$bootstrap" ] && [ -d "$bootstrap" ] && [ "$(stat -c '%U:%G %a' "$bootstrap")" = 'root:root 700' ] || exit 1
encoded="$bootstrap/.$asset.base64.tmp"
temporary="$bootstrap/.$asset.decoded.tmp"
destination="$bootstrap/$asset"
[ ! -L "$encoded" ] && [ -f "$encoded" ] && [ "$(stat -c '%U:%G %a' "$encoded")" = 'root:root 600' ] || exit 1
if [ -e "$temporary" ] || [ -L "$temporary" ]; then
    [ ! -L "$temporary" ] && [ -f "$temporary" ] && [ "$(stat -c '%U:%G %a' "$temporary")" = 'root:root 600' ] || exit 1
fi
if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ ! -L "$destination" ] && [ -f "$destination" ] && [ "$(stat -c '%U:%G %a' "$destination")" = "root:root $mode" ] || exit 1
fi
trap 'rm -f "$encoded" "$temporary"' EXIT
rm -f "$temporary"
(umask 077; base64 -d "$encoded" > "$temporary")
set -- $(sha256sum "$temporary")
[ "$1" = "$expected" ]
chown root:root "$temporary"
chmod "$mode" "$temporary"
mv -f "$temporary" "$destination"
rm -f "$encoded"
trap - EXIT
'@
}

function Get-WslBootstrapTransferCleanupCommand {
    return @'
set -eu
bootstrap=/root/openhands-bootstrap
asset=$1
case "$asset" in
    provision.sh|wsl.conf) ;;
    *) exit 1 ;;
esac
if [ ! -e "$bootstrap" ] && [ ! -L "$bootstrap" ]; then
    exit 0
fi
[ ! -L "$bootstrap" ] && [ -d "$bootstrap" ] && [ "$(stat -c '%U:%G %a' "$bootstrap")" = 'root:root 700' ] || exit 1
encoded="$bootstrap/.$asset.base64.tmp"
temporary="$bootstrap/.$asset.decoded.tmp"
for path in "$encoded" "$temporary"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ ! -L "$path" ] && [ -f "$path" ] && [ "$(stat -c '%U:%G %a' "$path")" = 'root:root 600' ] || exit 1
    fi
done
rm -f "$encoded" "$temporary"
'@
}

function Invoke-WslBootstrapAssetTransfer {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$AssetName,
        [Parameter(Mandatory)]$Asset
    )

    $wrapper = Get-WslShellProgramWrapper
    $initProgram = ConvertTo-WslShellProgramBase64 -Program (Get-WslBootstrapTransferInitCommand)
    $chunkProgram = ConvertTo-WslShellProgramBase64 -Program (Get-WslBootstrapTransferChunkCommand)
    $finalizeProgram = ConvertTo-WslShellProgramBase64 -Program (Get-WslBootstrapTransferFinalizeCommand)
    $cleanupProgram = ConvertTo-WslShellProgramBase64 -Program (Get-WslBootstrapTransferCleanupCommand)
    $failure = $null
    try {
        & $WslPath --distribution $Name --user root --exec sh -ec $wrapper sh $initProgram $AssetName
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to initialize bootstrap asset '$AssetName' in WSL distribution '$Name'."
        }

        for ($index = 0; $index -lt $Asset.Chunks.Count; $index++) {
            & $WslPath --distribution $Name --user root --exec sh -ec $wrapper sh $chunkProgram $AssetName $Asset.Chunks[$index]
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to transfer bootstrap asset '$AssetName' chunk $($index + 1) in WSL distribution '$Name'."
            }
        }

        & $WslPath --distribution $Name --user root --exec sh -ec $wrapper sh $finalizeProgram $AssetName $Asset.Sha256
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to finalize bootstrap asset '$AssetName' in WSL distribution '$Name'."
        }
    }
    catch {
        $failure = $_
    }

    if ($failure) {
        $cleanupFailure = $null
        try {
            & $WslPath --distribution $Name --user root --exec sh -ec $wrapper sh $cleanupProgram $AssetName
            if ($LASTEXITCODE -ne 0) {
                $cleanupFailure = "Unable to clean bootstrap asset '$AssetName' staging in WSL distribution '$Name'."
            }
        }
        catch {
            $cleanupFailure = $_.Exception.Message
        }

        if ($cleanupFailure) {
            throw "$($failure.Exception.Message) $cleanupFailure"
        }
        throw $failure
    }
}

function Get-WslBaseProvisioningVerificationCommand {
    return (@(
        'set -eu'
        '[ "$(id -un)" = agent ]'
        '[ "$(cat /proc/1/comm)" = systemd ]'
        'if [ -e /mnt/c ] || [ -L /mnt/c ]; then'
        '    if mountpoint -q /mnt/c; then'
        '        exit 1'
        '    elif [ "$?" -ne 32 ]; then'
        '        exit 1'
        '    fi'
        'fi'
        (Get-WslBaseProvisioningIsolationCommand)
        'for path in /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/workspaces; do'
        '    [ ! -L "$path" ] && [ -d "$path" ] && [ "$(stat -c ''%U:%G %a'' "$path")" = ''agent:agent 700'' ]'
        'done'
    ) -join "`n")
}

function Get-WslBaseProvisioningIsolationCommand {
    return (@(
        'set -e'
        '[ -z "${WSL_INTEROP:-}" ]'
        '[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]'
    ) -join "`n")
}

function Invoke-WslBaseProvisioning {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ProvisionPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    $provision = Get-WslBootstrapAsset -Path $ProvisionPath
    $config = Get-WslBootstrapAsset -Path $ConfigPath
    $wrapper = Get-WslShellProgramWrapper
    $verificationProgram = ConvertTo-WslShellProgramBase64 -Program (Get-WslBaseProvisioningVerificationCommand)

    $failure = $null
    $terminationFailure = $null
    try {
        foreach ($asset in @(
            [pscustomobject]@{ Name = "provision.sh"; Value = $provision },
            [pscustomobject]@{ Name = "wsl.conf"; Value = $config }
        )) {
            Invoke-WslBootstrapAssetTransfer -WslPath $WslPath -Name $Name -AssetName $asset.Name -Asset $asset.Value
        }

        & $WslPath --distribution $Name --user root --exec /bin/bash /root/openhands-bootstrap/provision.sh
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to provision WSL distribution '$Name'."
        }

        & $WslPath --terminate $Name
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to restart WSL distribution '$Name'."
        }

        & $WslPath --distribution $Name --exec sh -ec $wrapper sh $verificationProgram
        if ($LASTEXITCODE -ne 0) {
            throw "WSL distribution '$Name' failed post-provision verification."
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

$assetRoot = Split-Path -Parent $PSCommandPath
Invoke-WslBaseProvisioning -WslPath $wslPath -Name $DistroName -ProvisionPath (Join-Path $assetRoot "provision.sh") -ConfigPath (Join-Path $assetRoot "wsl.conf")
Write-Host "WSL bootstrap Stage 4 completed."
