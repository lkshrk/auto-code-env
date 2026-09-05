Set-StrictMode -Version Latest

$WorkerRepository = "lkshrk/auto-code-env"
$WorkerTagPrefix = "openhands-worker-v"
$WorkerVersionPattern = '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
$WorkerDistroPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
$WorkerLxssKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss"

function Get-WorkerJsonMember {
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object -or -not ($Object -is [psobject])) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function ConvertTo-WorkerStringArray {
    param($Value, [Parameter(Mandatory)][string]$Name)

    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }
        $text = [string]$item
        foreach ($part in ($text -split ",")) {
            $trimmed = $part.Trim()
            if ($trimmed -ne "") {
                $result.Add($trimmed)
            }
        }
    }
    if ($result.Count -eq 0) {
        throw "worker.json '$Name' must list at least one value."
    }
    return $result.ToArray()
}

function Read-WorkerConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Worker configuration '$Path' does not exist."
    }

    $document = $null
    try {
        $document = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        throw "Worker configuration '$Path' is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $document -or -not ($document -is [psobject])) {
        throw "Worker configuration '$Path' must contain a JSON object."
    }

    $distro = [string](Get-WorkerJsonMember -Object $document -Name "distro")
    if ([string]::IsNullOrWhiteSpace($distro)) {
        $distro = "openhands-worker"
    }
    if ($distro -notmatch $WorkerDistroPattern) {
        throw "worker.json 'distro' value '$distro' is not a valid distribution name."
    }

    $arch = [string](Get-WorkerJsonMember -Object $document -Name "arch")
    if (-not [string]::IsNullOrWhiteSpace($arch) -and $arch -cnotin @("amd64", "arm64")) {
        throw "worker.json 'arch' must be 'amd64' or 'arm64'."
    }

    $release = [string](Get-WorkerJsonMember -Object $document -Name "release")
    if ([string]::IsNullOrWhiteSpace($release)) {
        $release = "latest"
    }

    $repository = [string](Get-WorkerJsonMember -Object $document -Name "repository")
    if ([string]::IsNullOrWhiteSpace($repository)) {
        $repository = $WorkerRepository
    }
    if ($repository -notmatch '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') {
        throw "worker.json 'repository' must be '<owner>/<name>'."
    }

    $remote = ConvertTo-WorkerStringArray -Value (Get-WorkerJsonMember -Object $document -Name "remoteAddresses") -Name "remoteAddresses"
    $origins = ConvertTo-WorkerStringArray -Value (Get-WorkerJsonMember -Object $document -Name "origins") -Name "origins"

    $vault = Get-WorkerJsonMember -Object $document -Name "vault"
    $vaultUrl = [string](Get-WorkerJsonMember -Object $vault -Name "url")
    $vaultEmail = [string](Get-WorkerJsonMember -Object $vault -Name "email")
    if ($vaultUrl -notmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$') {
        throw "worker.json 'vault.url' must be an absolute HTTPS URL."
    }
    if ($vaultEmail -notmatch '^[^@\s]+@[^@\s]+$') {
        throw "worker.json 'vault.email' must be an email address."
    }

    $items = Get-WorkerJsonMember -Object $document -Name "items"
    $resolvedItems = @{}
    foreach ($name in @("crt", "key", "api", "pat", "ca")) {
        $value = [string](Get-WorkerJsonMember -Object $items -Name $name)
        if ($value -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            throw "worker.json 'items.$name' must be a lowercase vault item UUID."
        }
        $resolvedItems[$name] = $value
    }

    $profileValue = [string](Get-WorkerJsonMember -Object $document -Name "profile")
    if ([string]::IsNullOrWhiteSpace($profileValue)) {
        throw "worker.json 'profile' is required."
    }

    return [pscustomobject]@{
        Distro          = $distro
        Architecture    = $arch
        Release         = $release
        Repository      = $repository
        RemoteAddresses = $remote
        Origins         = $origins
        VaultUrl        = $vaultUrl
        VaultEmail      = $vaultEmail
        Items           = $resolvedItems
        Profile         = $profileValue
    }
}

function Get-WorkerVersionFromTag {
    param([Parameter(Mandatory)][string]$Tag)

    if (-not $Tag.StartsWith($WorkerTagPrefix, [StringComparison]::Ordinal)) {
        throw "Release tag '$Tag' must start with '$WorkerTagPrefix'."
    }
    $version = $Tag.Substring($WorkerTagPrefix.Length)
    if ($version -notmatch $WorkerVersionPattern) {
        throw "Release tag '$Tag' does not carry a valid version."
    }
    return $version
}

function Select-WorkerReleaseTag {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Releases)

    $best = $null
    $bestVersion = $null
    foreach ($release in $Releases) {
        $tag = [string](Get-WorkerJsonMember -Object $release -Name "tag_name")
        if ($tag -notmatch ('^' + [regex]::Escape($WorkerTagPrefix) + '[0-9]+\.[0-9]+\.[0-9]+$')) {
            continue
        }
        if ((Get-WorkerJsonMember -Object $release -Name "draft") -eq $true) {
            continue
        }
        if ((Get-WorkerJsonMember -Object $release -Name "prerelease") -eq $true) {
            continue
        }
        $version = [version]$tag.Substring($WorkerTagPrefix.Length)
        if ($null -eq $bestVersion -or $version -gt $bestVersion) {
            $best = $tag
            $bestVersion = $version
        }
    }
    if ($null -eq $best) {
        throw "No published '$WorkerTagPrefix*' release was found."
    }
    return $best
}

function Get-WorkerInstalledVersion {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Output)

    if ($null -eq $Output) {
        return $null
    }
    $normalized = ($Output -replace [string][char]0, "") -join "`n"
    $match = [regex]::Match($normalized, '(?m)^openhands-worker[ \t]+(?<version>\S+)[ \t]*$')
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups["version"].Value
}

function Compare-WorkerVersion {
    param([AllowNull()][string]$Installed, [Parameter(Mandatory)][string]$Target)

    if ($Target -notmatch $WorkerVersionPattern) {
        throw "Target version '$Target' is not a release version."
    }
    if ([string]::IsNullOrWhiteSpace($Installed) -or $Installed -notmatch $WorkerVersionPattern) {
        return -1
    }

    $split = {
        param([string]$Value)
        $parts = $Value -split '(?<=^[0-9]+\.[0-9]+\.[0-9]+)[.-]', 2
        return [pscustomobject]@{ Core = [version]$parts[0]; PreRelease = $(if ($parts.Count -gt 1) { $parts[1] } else { "" }) }
    }

    $left = & $split $Installed
    $right = & $split $Target
    $core = $left.Core.CompareTo($right.Core)
    if ($core -ne 0) {
        return [Math]::Sign($core)
    }
    if ($left.PreRelease -ceq $right.PreRelease) {
        return 0
    }
    if ($left.PreRelease -eq "") {
        return 1
    }
    if ($right.PreRelease -eq "") {
        return -1
    }
    return [Math]::Sign([string]::CompareOrdinal($left.PreRelease, $right.PreRelease))
}

function Get-WorkerFileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

function Read-WorkerChecksums {
    param([Parameter(Mandatory)][string]$Path)

    $checksums = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.Trim() -eq "") {
            continue
        }
        if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})\s+\*?(?<name>\S.*?)\s*$') {
            throw "checksums.txt line '$line' is not a sha256sum entry."
        }
        $name = $Matches["name"]
        if ($name -match '[\\/]' -or $name -eq "." -or $name -eq "..") {
            throw "checksums.txt entry '$name' must be a release asset name."
        }
        if ($checksums.ContainsKey($name)) {
            throw "checksums.txt lists '$name' more than once."
        }
        $checksums[$name] = $Matches["hash"].ToLowerInvariant()
    }
    if ($checksums.Count -eq 0) {
        throw "checksums.txt is empty."
    }
    return $checksums
}

function Assert-WorkerAsset {
    param(
        [Parameter(Mandatory)][hashtable]$Checksums,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not $Checksums.ContainsKey($Name)) {
        throw "Release asset '$Name' is not listed in checksums.txt."
    }
    $actual = Get-WorkerFileSha256 -Path $Path
    if ($actual -cne $Checksums[$Name]) {
        throw "Release asset '$Name' failed checksum verification."
    }
    return $Checksums[$Name]
}

function Get-WorkerAssetUri {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Name
    )

    return "https://github.com/$Repository/releases/download/$Tag/$Name"
}

function Save-WorkerAsset {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][scriptblock]$Download,
        [hashtable]$Checksums
    )

    $path = Join-Path $Directory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        & $Download (Get-WorkerAssetUri -Repository $Repository -Tag $Tag -Name $Name) $path
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Release asset '$Name' was not downloaded."
    }
    if ($PSBoundParameters.ContainsKey("Checksums")) {
        try {
            Assert-WorkerAsset -Checksums $Checksums -Name $Name -Path $path | Out-Null
        }
        catch {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            throw
        }
    }
    return $path
}

function Get-WorkerVaultCredential {
    param(
        [Parameter(Mandatory)][string]$Path,
        [System.Security.SecureString]$VaultPassword,
        [scriptblock]$Prompt = { Read-Host -Prompt "Vaultwarden master password" -AsSecureString }
    )

    if ($PSBoundParameters.ContainsKey("VaultPassword") -and $null -ne $VaultPassword) {
        if ($VaultPassword.Length -eq 0) {
            throw "The vault master password must not be empty."
        }
        $credential = New-Object System.Management.Automation.PSCredential("vault", $VaultPassword)
        Save-WorkerVaultCredential -Path $Path -Credential $credential
        return $credential
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $stored = Import-Clixml -LiteralPath $Path
        if (-not ($stored -is [System.Management.Automation.PSCredential]) -or $stored.Password.Length -eq 0) {
            throw "Stored vault credential '$Path' is not a usable PSCredential; delete it and run again."
        }
        return $stored
    }

    $secure = & $Prompt
    if (-not ($secure -is [System.Security.SecureString]) -or $secure.Length -eq 0) {
        throw "The vault master password must not be empty."
    }
    $credential = New-Object System.Management.Automation.PSCredential("vault", $secure)
    Save-WorkerVaultCredential -Path $Path -Credential $credential
    return $credential
}

function Save-WorkerVaultCredential {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $Credential | Export-Clixml -LiteralPath $Path -Force
}

function Get-WorkerOverlayArguments {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string[]]$Command,
        [switch]$PasswordStdin
    )

    if ($Distro -notmatch $WorkerDistroPattern) {
        throw "Distribution name '$Distro' is not valid."
    }
    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $arguments.AddRange([string[]]@("--distribution", $Distro, "--user", "root", "--exec", "/usr/local/sbin/openhands-overlay"))
    $arguments.AddRange([string[]]$Command)
    if ($PasswordStdin) {
        $arguments.Add("--password-stdin")
    }
    return $arguments.ToArray()
}

function Get-WorkerPasswordBytes {
    param([Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ($plain -match "[`r`n]") {
            throw "The vault master password must not contain a line break."
        }
        return [System.Text.Encoding]::UTF8.GetBytes($plain + "`n")
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function ConvertTo-WorkerArgument {
    param([AllowEmptyString()][string]$Value)

    if ($Value -ne "" -and $Value -notmatch '[\s"]') {
        return $Value
    }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($char in $Value.ToCharArray()) {
        if ($char -eq '\') {
            $backslashes++
            continue
        }
        if ($char -eq '"') {
            [void]$builder.Append('\' * ($backslashes * 2 + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        [void]$builder.Append('\' * $backslashes)
        [void]$builder.Append($char)
        $backslashes = 0
    }
    [void]$builder.Append('\' * ($backslashes * 2))
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-WorkerCommandLine {
    param([AllowEmptyCollection()][string[]]$Arguments)

    return (($Arguments | ForEach-Object { ConvertTo-WorkerArgument -Value $_ }) -join " ")
}

function Invoke-WorkerProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [byte[]]$InputBytes,
        [string]$InputPath,
        [string]$OutputPath
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = ConvertTo-WorkerCommandLine -Arguments $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = ($null -ne $InputBytes -or -not [string]::IsNullOrEmpty($InputPath))
    $info.RedirectStandardOutput = -not [string]::IsNullOrEmpty($OutputPath)

    $process = [System.Diagnostics.Process]::Start($info)
    try {
        if ($info.RedirectStandardInput) {
            $stdin = $process.StandardInput.BaseStream
            try {
                if ($null -ne $InputBytes) {
                    $stdin.Write($InputBytes, 0, $InputBytes.Length)
                }
                else {
                    $source = [IO.File]::Open($InputPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                    try {
                        $source.CopyTo($stdin)
                    }
                    finally {
                        $source.Dispose()
                    }
                }
                $stdin.Flush()
            }
            finally {
                $process.StandardInput.Close()
            }
        }
        if ($info.RedirectStandardOutput) {
            $destination = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $process.StandardOutput.BaseStream.CopyTo($destination)
            }
            finally {
                $destination.Dispose()
            }
        }
        $process.WaitForExit()
        return $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-WorkerOverlay {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string[]]$Command,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$InputPath,
        [string]$OutputPath
    )

    $usePassword = $null -ne $Credential
    $arguments = Get-WorkerOverlayArguments -Distro $Distro -Command $Command -PasswordStdin:$usePassword
    $bytes = $null
    try {
        if ($usePassword) {
            $bytes = Get-WorkerPasswordBytes -Credential $Credential
        }
        $parameters = @{ FilePath = $WslPath; Arguments = $arguments }
        if ($null -ne $bytes) {
            $parameters["InputBytes"] = $bytes
        }
        if (-not [string]::IsNullOrEmpty($InputPath)) {
            $parameters["InputPath"] = $InputPath
        }
        if (-not [string]::IsNullOrEmpty($OutputPath)) {
            $parameters["OutputPath"] = $OutputPath
        }
        $exit = Invoke-WorkerProcess @parameters
    }
    finally {
        if ($null -ne $bytes) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
    if ($exit -ne 0) {
        throw "openhands-overlay $($Command -join ' ') failed with exit code $exit."
    }
}

function Copy-WorkerFileToDistribution {
    param(
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Mode
    )

    if ($Destination -notmatch '^(/[A-Za-z0-9._-]+)+$') {
        throw "Destination '$Destination' must be an absolute path without shell metacharacters."
    }
    if ($Mode -notmatch '^0[0-7]{3}$') {
        throw "Mode '$Mode' must be octal."
    }
    $staging = $Destination + ".new"
    $shell = "set -e; cat > '$staging'; chown root:root '$staging'; chmod $Mode '$staging'; mv '$staging' '$Destination'"
    $arguments = @("--distribution", $Distro, "--user", "root", "--exec", "/bin/sh", "-c", $shell)
    $exit = Invoke-WorkerProcess -FilePath $WslPath -Arguments $arguments -InputPath $Path
    if ($exit -ne 0) {
        throw "Copying '$Path' into '$Destination' on '$Distro' failed with exit code $exit."
    }
}

function Get-WslDistributionRegistryKey {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$GetKeys,
        [Parameter(Mandatory)][scriptblock]$GetName
    )

    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @(& $GetKeys)) {
        if ([string](& $GetName $key) -ceq $Name) {
            $found.Add([string]$key)
        }
    }
    if ($found.Count -ne 1) {
        throw "Expected exactly one Lxss registry key for distribution '$Name', found $($found.Count)."
    }
    return $found[0]
}

function Rename-WslDistribution {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][scriptblock]$GetKeys,
        [Parameter(Mandatory)][scriptblock]$GetName,
        [Parameter(Mandatory)][scriptblock]$SetName
    )

    if ($To -notmatch $WorkerDistroPattern) {
        throw "Distribution name '$To' is not valid."
    }
    $key = Get-WslDistributionRegistryKey -Name $From -GetKeys $GetKeys -GetName $GetName
    foreach ($candidate in @(& $GetKeys)) {
        if ([string](& $GetName $candidate) -ceq $To) {
            throw "Distribution '$To' is still registered; refusing to rename '$From' onto it."
        }
    }
    & $SetName $key $To
    return $key
}

function Get-WorkerWslPath {
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

function Get-WorkerArchitecture {
    param(
        [string]$Architecture = $env:PROCESSOR_ARCHITECTURE,
        [string]$Wow64Architecture = $env:PROCESSOR_ARCHITEW6432
    )

    $detected = if (-not [string]::IsNullOrWhiteSpace($Wow64Architecture)) { $Wow64Architecture } elseif (-not [string]::IsNullOrWhiteSpace($Architecture)) { $Architecture } else { [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }
    switch ($detected.ToUpperInvariant()) {
        "AMD64" { return "amd64" }
        "ARM64" { return "arm64" }
        default { throw "Unsupported Windows architecture '$detected'." }
    }
}

function Test-WorkerDistributionRegistered {
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string[]]$Output,
        [Parameter(Mandatory)][string]$Name
    )

    return [bool]((($Output -replace [string][char]0, "") -join "`n") -match ("(?m)^\s*" + [regex]::Escape($Name) + "\s*$"))
}

function Assert-WorkerElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object -TypeName Security.Principal.WindowsPrincipal -ArgumentList $identity
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an elevated PowerShell session."
    }
    return $identity
}

function Get-WorkerConfigPath {
    param([string]$Path, [string]$ProgramData = $env:ProgramData)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    if ([string]::IsNullOrWhiteSpace($ProgramData)) {
        throw "Unable to locate ProgramData; pass -Config explicitly."
    }
    return Join-Path $ProgramData "openhands-worker\worker.json"
}

function Get-WorkerCredentialPath {
    param([string]$LocalAppData = $env:LOCALAPPDATA)

    if ([string]::IsNullOrWhiteSpace($LocalAppData)) {
        throw "Unable to locate LOCALAPPDATA for the vault credential store."
    }
    return Join-Path $LocalAppData "openhands-worker\vault.cred"
}

function Get-WorkerAssetNames {
    param(
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][string]$ProfileAsset
    )

    if ($Architecture -cnotin @("amd64", "arm64")) {
        throw "Architecture '$Architecture' must be 'amd64' or 'arm64'."
    }
    $names = New-Object 'System.Collections.Generic.List[string]'
    $names.AddRange([string[]]@("install.ps1", "firewall.ps1", "keepalive.ps1", "openhands-overlay", "openhands-worker-$Version-$Architecture.wsl"))
    if ($ProfileAsset -match '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') {
        $names.Add($ProfileAsset)
    }
    return $names.ToArray()
}

function Resolve-WorkerProfilePath {
    param(
        [Parameter(Mandatory)][string]$ProfileAsset,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][scriptblock]$Download
    )

    if ($ProfileAsset -match '^[A-Za-z0-9][A-Za-z0-9._-]*\.json$') {
        return Join-Path $Directory $ProfileAsset
    }
    if ($ProfileAsset -match '^https://') {
        $path = Join-Path $Directory ("downloaded-" + [IO.Path]::GetFileName(([Uri]$ProfileAsset).AbsolutePath))
        & $Download $ProfileAsset $path
        return $path
    }
    if (-not (Test-Path -LiteralPath $ProfileAsset -PathType Leaf)) {
        throw "Settings profile '$ProfileAsset' is not a release asset name, an HTTPS URL, or an existing file."
    }
    return (Get-Item -LiteralPath $ProfileAsset -Force).FullName
}

function Get-WorkerReleaseAssets {
    param(
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][scriptblock]$Download
    )

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $checksumPath = Join-Path $Directory "checksums.txt"
    Remove-Item -LiteralPath $checksumPath -Force -ErrorAction SilentlyContinue
    & $Download (Get-WorkerAssetUri -Repository $Configuration.Repository -Tag $Tag -Name "checksums.txt") $checksumPath
    $checksums = Read-WorkerChecksums -Path $checksumPath

    $version = Get-WorkerVersionFromTag -Tag $Tag
    $resolved = @{}
    foreach ($name in (Get-WorkerAssetNames -Version $version -Architecture $Architecture -ProfileAsset $Configuration.Profile)) {
        $resolved[$name] = Save-WorkerAsset -Repository $Configuration.Repository -Tag $Tag -Name $name `
            -Directory $Directory -Download $Download -Checksums $checksums
    }

    return [pscustomobject]@{
        Directory = $Directory
        Checksums = $checksums
        Paths     = $resolved
        Version   = $version
        Image     = $resolved["openhands-worker-$version-$Architecture.wsl"]
        ImageHash = $checksums["openhands-worker-$version-$Architecture.wsl"]
    }
}

function Invoke-WorkerProvision {
    param(
        [Parameter(Mandatory)][pscustomobject]$Configuration,
        [Parameter(Mandatory)][string]$OverlayPath,
        [Parameter(Mandatory)][string]$ProfilePath,
        [AllowNull()][AllowEmptyString()][string]$StatePath,
        [Parameter(Mandatory)][scriptblock]$CopyFile,
        [Parameter(Mandatory)][scriptblock]$Overlay
    )

    & $CopyFile $OverlayPath "/usr/local/sbin/openhands-overlay" "0755"
    & $CopyFile $ProfilePath "/etc/openhands/profile.json" "0600"

    & $Overlay @("ca", "--vault-url", $Configuration.VaultUrl, "--email", $Configuration.VaultEmail, "--item", $Configuration.Items["ca"]) $true $null
    & $Overlay @("secrets", "--vault-url", $Configuration.VaultUrl, "--email", $Configuration.VaultEmail,
        "--crt-id", $Configuration.Items["crt"], "--key-id", $Configuration.Items["key"], "--api-id", $Configuration.Items["api"]) $true $null
    & $Overlay @("github", "--pat-id", $Configuration.Items["pat"]) $true $null
    & $Overlay (@("origin") + $Configuration.Origins) $false $null
    if (-not [string]::IsNullOrEmpty($StatePath)) {
        & $Overlay @("state", "import") $false $StatePath
    }
}

function Invoke-WorkerActivation {
    param([Parameter(Mandatory)][scriptblock]$Overlay)

    & $Overlay @("enable") $false $null
    & $Overlay @("settings", "--file", "/etc/openhands/profile.json") $true $null
    & $Overlay @("verify") $false $null
}
