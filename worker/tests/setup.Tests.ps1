$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw "$Message."
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $Pattern) {
            throw "$Message. Pattern '$Pattern' was not found in '$($_.Exception.Message)'."
        }
        return
    }

    throw "$Message. Expected an exception."
}

function Import-ScriptFunction {
    param([string]$Path, [string]$Name)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) {
        throw ($errors | Out-String)
    }

    $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    if (-not $function) {
        throw "$Name is missing from $Path."
    }

    return $function.Extent.Text
}

$windows = Join-Path $PSScriptRoot "..\windows"
$commonPath = Join-Path $windows "common.ps1"
$setupPath = Join-Path $windows "setup.ps1"

$WorkerRepository = "lkshrk/auto-code-env"
$WorkerTagPrefix = "openhands-worker-v"
$WorkerVersionPattern = '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
$WorkerDistroPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

foreach ($name in "Get-WorkerJsonMember", "ConvertTo-WorkerStringArray", "Read-WorkerConfig", "Get-WorkerVersionFromTag",
    "Select-WorkerReleaseTag", "Get-WorkerFileSha256", "Read-WorkerChecksums", "Assert-WorkerAsset", "Get-WorkerAssetUri",
    "Save-WorkerAsset", "Get-WorkerVaultCredential", "Save-WorkerVaultCredential", "Get-WorkerOverlayArguments",
    "Get-WorkerPasswordBytes", "ConvertTo-WorkerArgument", "ConvertTo-WorkerCommandLine", "Invoke-WorkerProcess", "Invoke-WorkerOverlay", "Get-WorkerAssetNames",
    "Resolve-WorkerProfilePath", "Get-WorkerConfigPath", "Get-WorkerCredentialPath", "Invoke-WorkerProvision",
    "Invoke-WorkerActivation", "Resolve-WorkerCommonProfileName", "Get-WorkerSettingsCommand",
    "Get-WorkerGuestProfilePaths") {
    Invoke-Expression (Import-ScriptFunction -Path $commonPath -Name $name)
}

$setupSource = Get-Content -Raw $setupPath
foreach ($required in 'Assert-WorkerElevated', 'Read-WorkerConfig', 'Get-WorkerReleaseAssets', 'Invoke-WorkerProvision',
    'Invoke-WorkerActivation', 'install\.ps1', 'firewall\.ps1', 'keepalive\.ps1', '-Replace') {
    if ($setupSource -notmatch $required) {
        throw "setup.ps1 must use $required."
    }
}
if ($setupSource -match 'ConvertFrom-SecureString\s+[^|]*-AsPlainText' -or $setupSource -match 'Out-File.*[Pp]assword') {
    throw "setup.ps1 must never write the vault password to disk."
}
Write-Host "PASS: setup.ps1 shape"

$root = Join-Path ([IO.Path]::GetTempPath()) ("worker-setup-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $assetDirectory = Join-Path $root "assets"
    New-Item -ItemType Directory -Path $assetDirectory | Out-Null
    $goodPath = Join-Path $assetDirectory "install.ps1"
    [IO.File]::WriteAllText($goodPath, "installer")
    $goodHash = Get-WorkerFileSha256 -Path $goodPath
    Assert-Equal 64 $goodHash.Length "sha256 is 64 hex characters"

    $checksumPath = Join-Path $assetDirectory "checksums.txt"
    [IO.File]::WriteAllText($checksumPath, "$goodHash  install.ps1`n$('0' * 64)  keepalive.ps1`n")
    $checksums = Read-WorkerChecksums -Path $checksumPath
    Assert-Equal 2 $checksums.Count "checksums.txt lists two assets"
    Assert-Equal $goodHash (Assert-WorkerAsset -Checksums $checksums -Name "install.ps1" -Path $goodPath) "matching asset verifies"

    $badPath = Join-Path $assetDirectory "keepalive.ps1"
    [IO.File]::WriteAllText($badPath, "tampered")
    Assert-Throws { Assert-WorkerAsset -Checksums $checksums -Name "keepalive.ps1" -Path $badPath } "failed checksum verification" "a tampered asset is refused"
    Assert-Throws { Assert-WorkerAsset -Checksums $checksums -Name "firewall.ps1" -Path $goodPath } "not listed in checksums.txt" "an unlisted asset is refused"

    [IO.File]::WriteAllText($checksumPath, "$goodHash  ../escape.ps1`n")
    Assert-Throws { Read-WorkerChecksums -Path $checksumPath } "must be a release asset name" "checksums.txt path traversal is refused"
    [IO.File]::WriteAllText($checksumPath, "not a checksum line`n")
    Assert-Throws { Read-WorkerChecksums -Path $checksumPath } "is not a sha256sum entry" "malformed checksums.txt is refused"
    Write-Host "PASS: checksum verification"

    $downloads = New-Object 'System.Collections.Generic.List[string]'
    $download = {
        param($uri, $path)
        $downloads.Add($uri)
        [IO.File]::WriteAllText($path, "tampered")
    }
    $downloadDirectory = Join-Path $root "download"
    New-Item -ItemType Directory -Path $downloadDirectory | Out-Null
    Assert-Throws {
        Save-WorkerAsset -Repository $WorkerRepository -Tag "openhands-worker-v1.2.3" -Name "install.ps1" `
            -Directory $downloadDirectory -Download $download -Checksums $checksums
    } "failed checksum verification" "a mismatching download is refused"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $downloadDirectory "install.ps1"))) "a mismatching download is deleted before any state change"
    Assert-Equal "https://github.com/lkshrk/auto-code-env/releases/download/openhands-worker-v1.2.3/install.ps1" $downloads[0] "release asset URI"
    Write-Host "PASS: download verification"

    $configPath = Join-Path $root "worker.json"
    $configJson = @'
{
  "distro": "openhands-worker",
  "release": "openhands-worker-v0.3.0",
  "remoteAddresses": ["10.254.0.10", "10.254.0.11"],
  "vault": { "url": "https://vlt.h-cloud.io", "email": "agent-worker@harke.me" },
  "items": {
    "crt": "2924548c-ec74-4fd3-9181-b303cd574dbb",
    "key": "a9e6c601-77b3-47b6-980d-493743b7d7da",
    "api": "b9ba25a8-0b4f-45ef-9236-2504c2ba807c",
    "pat": "28226043-0a70-4d54-bfb8-592086a319c0",
    "ca": "cf9ec766-c260-4e7d-abe0-3299745b57b4"
  },
  "origins": ["https://orc.ai.h-cloud.lan"],
  "profile": "profile-towerr.json"
}
'@
    [IO.File]::WriteAllText($configPath, $configJson)
    $configuration = Read-WorkerConfig -Path $configPath
    Assert-Equal "openhands-worker" $configuration.Distro "distro"
    Assert-Equal $WorkerRepository $configuration.Repository "repository defaults to the worker repository"
    Assert-Equal "" $configuration.Architecture "architecture is auto-detected when absent"
    Assert-Equal 2 $configuration.RemoteAddresses.Count "remote addresses"
    Assert-Equal "cf9ec766-c260-4e7d-abe0-3299745b57b4" $configuration.Items["ca"] "ca item"
    Assert-Equal "profile-common.json" $configuration.ProfileCommon "profileCommon defaults to the shared release asset"

    [IO.File]::WriteAllText($configPath, ($configJson -replace '"profile": "profile-towerr.json"', '"profile": "profile-towerr.json", "profileCommon": "profile-shared.json"'))
    Assert-Equal "profile-shared.json" (Read-WorkerConfig -Path $configPath).ProfileCommon "profileCommon is read from worker.json"
    [IO.File]::WriteAllText($configPath, ($configJson -replace '"profile": "profile-towerr.json"', '"profile": "profile-towerr.json", "profileCommon": "../escape.json"'))
    Assert-Throws { Read-WorkerConfig -Path $configPath } "profileCommon" "a profileCommon that is not a release asset name is refused"
    [IO.File]::WriteAllText($configPath, $configJson)

    foreach ($case in @(
            @{ Pattern = 'remoteAddresses'; Json = $configJson -replace '"remoteAddresses": \[[^\]]*\]', '"remoteAddresses": []' },
            @{ Pattern = 'items.pat'; Json = $configJson -replace '"pat": "[^"]*"', '"pat": "TODO"' },
            @{ Pattern = 'vault.url'; Json = $configJson -replace '"url": "[^"]*"', '"url": "http://vlt.h-cloud.io"' },
            @{ Pattern = 'vault.email'; Json = $configJson -replace '"email": "[^"]*"', '"email": "nobody"' },
            @{ Pattern = "'profile' is required"; Json = $configJson -replace '"profile": "[^"]*"', '"profile": ""' },
            @{ Pattern = 'origins'; Json = $configJson -replace '"origins": \[[^\]]*\]', '"origins": []' })) {
        [IO.File]::WriteAllText($configPath, $case.Json)
        Assert-Throws { Read-WorkerConfig -Path $configPath } ([regex]::Escape($case.Pattern)) "worker.json rejects a missing or invalid $($case.Pattern)"
    }
    [IO.File]::WriteAllText($configPath, $configJson)
    $programData = Join-Path $root "ProgramData"
    Assert-Equal (Join-Path $programData "openhands-worker\worker.json") (Get-WorkerConfigPath -Path "" -ProgramData $programData) "default config path"
    Assert-Equal "C:\custom.json" (Get-WorkerConfigPath -Path "C:\custom.json" -ProgramData $programData) "explicit config path wins"
    Assert-Equal (Join-Path $programData "openhands-worker\vault.cred") (Get-WorkerCredentialPath -LocalAppData $programData) "credential path"
    Assert-Throws { Get-WorkerConfigPath -Path "" -ProgramData "" } "pass -Config explicitly" "a missing ProgramData is reported"
    Assert-Throws { Get-WorkerCredentialPath -LocalAppData "" } "LOCALAPPDATA" "a missing LOCALAPPDATA is reported"
    Write-Host "PASS: worker.json validation"

    $names = Get-WorkerAssetNames -Version "1.2.3" -Architecture "amd64" -ProfileAsset "profile-towerr.json"
    Assert-Equal "install.ps1 firewall.ps1 keepalive.ps1 openhands-overlay openhands-worker-1.2.3-amd64.wsl profile-towerr.json" ($names -join " ") "amd64 asset list"
    Assert-Equal "openhands-worker-1.2.3-arm64.wsl" (Get-WorkerAssetNames -Version "1.2.3" -Architecture "arm64" -ProfileAsset "https://example.invalid/p.json")[4] "arm64 image name"
    Assert-Equal 5 (Get-WorkerAssetNames -Version "1.2.3" -Architecture "arm64" -ProfileAsset "https://example.invalid/p.json").Count "a URL profile is not a release asset"
    Assert-Throws { Get-WorkerAssetNames -Version "1.2.3" -Architecture "armv7" -ProfileAsset "p.json" } "must be 'amd64' or 'arm64'" "unknown architecture is refused"
    Assert-Equal "1.2.3" (Get-WorkerVersionFromTag -Tag "openhands-worker-v1.2.3") "tag to version"
    Assert-Throws { Get-WorkerVersionFromTag -Tag "v1.2.3" } "must start with" "a foreign tag is refused"
    Assert-Equal "openhands-worker-v0.3.0" (Select-WorkerReleaseTag -Releases @(
            [pscustomobject]@{ tag_name = "openhands-worker-v0.2.9"; draft = $false; prerelease = $false },
            [pscustomobject]@{ tag_name = "openhands-worker-v0.4.0"; draft = $true; prerelease = $false },
            [pscustomobject]@{ tag_name = "openhands-worker-v0.5.0"; draft = $false; prerelease = $true },
            [pscustomobject]@{ tag_name = "other-v9.9.9"; draft = $false; prerelease = $false },
            [pscustomobject]@{ tag_name = "openhands-worker-v0.3.0"; draft = $false; prerelease = $false })) "latest resolves to the newest published worker release"
    Assert-Throws { Select-WorkerReleaseTag -Releases @() } "No published" "an empty release list is refused"

    $profileFile = Join-Path $root "local-profile.json"
    [IO.File]::WriteAllText($profileFile, "{}")
    Assert-Equal (Join-Path $assetDirectory "profile-towerr.json") (Resolve-WorkerProfilePath -ProfileAsset "profile-towerr.json" -Directory $assetDirectory -Download $download) "release asset profile"
    Assert-Equal $profileFile (Resolve-WorkerProfilePath -ProfileAsset $profileFile -Directory $assetDirectory -Download $download) "local profile path"
    Assert-Throws { Resolve-WorkerProfilePath -ProfileAsset "no-such-profile" -Directory $assetDirectory -Download $download } "is not a release asset name" "an unusable profile is refused"

    $commonChecksums = @{ "profile-common.json" = ("0" * 64); "profile-towerr.json" = ("0" * 64) }
    Assert-Equal "profile-common.json" (Resolve-WorkerCommonProfileName -ProfileCommon "profile-common.json" -Checksums $commonChecksums) "a published common profile is resolved"
    Assert-Equal "" (Resolve-WorkerCommonProfileName -ProfileCommon "profile-common.json" -Checksums @{ "profile-towerr.json" = ("0" * 64) }) "a release without the common profile falls back to the host profile alone"
    Assert-Equal "" (Resolve-WorkerCommonProfileName -ProfileCommon "" -Checksums $commonChecksums) "an empty profileCommon resolves to nothing"
    Assert-Equal "" (Resolve-WorkerCommonProfileName -ProfileCommon "../escape.json" -Checksums $commonChecksums) "a path-like profileCommon resolves to nothing"

    Assert-Equal "/etc/openhands/profile.json" ((Get-WorkerGuestProfilePaths -CommonProfilePath "") -join " ") "no common profile means one settings file"
    Assert-Equal "/etc/openhands/profile-common.json /etc/openhands/profile.json" ((Get-WorkerGuestProfilePaths -CommonProfilePath "C:\assets\profile-common.json") -join " ") "the common profile is layered under the host profile"
    Assert-Equal "settings --file /etc/openhands/profile-common.json --file /etc/openhands/profile.json" `
        ((Get-WorkerSettingsCommand -ProfilePaths @("/etc/openhands/profile-common.json", "/etc/openhands/profile.json")) -join " ") "layered settings command"
    Assert-Throws { Get-WorkerSettingsCommand -ProfilePaths @() } "At least one settings profile" "an empty profile list is refused"
    Assert-Throws { Get-WorkerSettingsCommand -ProfilePaths @("/etc/openhands/profile.json; rm -rf /") } "must be absolute" "a profile path with shell metacharacters is refused"
    Write-Host "PASS: release asset selection"

    $credentialPath = Join-Path $root "vault.cred"
    $secure = ConvertTo-SecureString "correct horse battery staple" -AsPlainText -Force
    $stored = Get-WorkerVaultCredential -Path $credentialPath -VaultPassword $secure
    Assert-Equal "vault" $stored.UserName "credential user name"
    Assert-True (Test-Path -LiteralPath $credentialPath) "the credential file is created"
    $raw = [IO.File]::ReadAllText($credentialPath)
    Assert-True (-not $raw.Contains("correct horse battery staple")) "the credential file never holds the password in plaintext"
    $reloaded = Get-WorkerVaultCredential -Path $credentialPath
    Assert-Equal "correct horse battery staple" ([Net.NetworkCredential]::new("", $reloaded.Password).Password) "the protected credential round-trips"
    [IO.File]::WriteAllText($credentialPath, "not a credential")
    Assert-Throws { Get-WorkerVaultCredential -Path $credentialPath } "." "a corrupt credential file is refused"
    Remove-Item -LiteralPath $credentialPath -Force
    Assert-Throws { Get-WorkerVaultCredential -Path $credentialPath -Prompt { ConvertTo-SecureString "x" -AsPlainText -Force | ForEach-Object { $_.Clear(); $_ } } } "must not be empty" "an empty prompt answer is refused"
    Write-Host "PASS: DPAPI-protected vault credential"

    $overlayArguments = Get-WorkerOverlayArguments -Distro "openhands-worker" -Command @("ca", "--item", "cf9ec766-c260-4e7d-abe0-3299745b57b4") -PasswordStdin
    Assert-Equal "--distribution openhands-worker --user root --exec /usr/local/sbin/openhands-overlay ca --item cf9ec766-c260-4e7d-abe0-3299745b57b4 --password-stdin" ($overlayArguments -join " ") "overlay argument list"
    Assert-Throws { Get-WorkerOverlayArguments -Distro "bad name; rm" -Command @("status") } "is not valid" "a distro name with shell characters is refused"

    $fakeWsl = Join-Path $root "fake-wsl"
    [IO.File]::WriteAllText($fakeWsl, @'
#!/bin/sh
for argument in "$@"; do
    printf '%s\0' "$argument" >> "$FAKE_WSL_ARGV"
done
if [ "$FAKE_WSL_STDIN" != "" ]; then
    cat >> "$FAKE_WSL_STDIN"
fi
exit "${FAKE_WSL_EXIT:-0}"
'@)
    & chmod +x $fakeWsl
    $argvLog = Join-Path $root "argv.log"
    $stdinLog = Join-Path $root "stdin.log"
    $env:FAKE_WSL_ARGV = $argvLog
    $env:FAKE_WSL_STDIN = $stdinLog
    $env:FAKE_WSL_EXIT = "0"
    $credential = New-Object System.Management.Automation.PSCredential("vault", (ConvertTo-SecureString "s3cr3t-master" -AsPlainText -Force))
    Invoke-WorkerOverlay -WslPath $fakeWsl -Distro "openhands-worker" -Command @("secrets", "--api-id", "b9ba25a8-0b4f-45ef-9236-2504c2ba807c") -Credential $credential
    $argv = [IO.File]::ReadAllText($argvLog) -split [string][char]0 | Where-Object { $_ -ne "" }
    Assert-Equal "s3cr3t-master`n" ([IO.File]::ReadAllText($stdinLog)) "the master password reaches the overlay only through stdin"
    Assert-True ($argv -notcontains "s3cr3t-master") "the master password is never an argument"
    Assert-True ((@($argv) -join " ") -notmatch "s3cr3t") "no argument embeds the master password"
    Assert-True ($argv -contains "--password-stdin") "a credential turns on --password-stdin"
    Assert-Equal "--distribution" $argv[0] "wsl.exe is invoked with an explicit distribution"

    Remove-Item -LiteralPath $argvLog, $stdinLog -Force
    $env:FAKE_WSL_STDIN = ""
    $env:FAKE_WSL_EXIT = "3"
    Assert-Throws { Invoke-WorkerOverlay -WslPath $fakeWsl -Distro "openhands-worker" -Command @("verify") } "exit code 3" "a failing overlay command throws"
    $env:FAKE_WSL_EXIT = "0"
    $argv = [IO.File]::ReadAllText($argvLog) -split [string][char]0 | Where-Object { $_ -ne "" }
    Assert-True ($argv -notcontains "--password-stdin") "no credential means no --password-stdin"

    $outputPath = Join-Path $root "state.tar.gz"
    $binaryPath = Join-Path $root "binary.bin"
    $bytes = [byte[]](0..255)
    [IO.File]::WriteAllBytes($binaryPath, $bytes)
    $emitter = Join-Path $root "fake-emitter"
    [IO.File]::WriteAllText($emitter, "#!/bin/sh`ncat `"$binaryPath`"`n")
    & chmod +x $emitter
    Invoke-WorkerProcess -FilePath $emitter -Arguments @() -OutputPath $outputPath | Out-Null

    Assert-Equal "plain" (ConvertTo-WorkerArgument -Value "plain") "plain argument is not quoted"
    Assert-Equal '"with space"' (ConvertTo-WorkerArgument -Value "with space") "spaces are quoted"
    Assert-Equal '""' (ConvertTo-WorkerArgument -Value "") "empty argument becomes empty quotes"
    Assert-Equal '"say \"hi\""' (ConvertTo-WorkerArgument -Value 'say "hi"') "embedded quotes are escaped"
    Assert-Equal "-d openhands-worker --user root -- openhands-overlay secrets --password-stdin" (ConvertTo-WorkerCommandLine -Arguments @("-d", "openhands-worker", "--user", "root", "--", "openhands-overlay", "secrets", "--password-stdin")) "wsl arguments round-trip unquoted"
    Write-Host "PASS: command line quoting for Windows PowerShell 5.1"
    Assert-Equal ([Convert]::ToBase64String($bytes)) ([Convert]::ToBase64String([IO.File]::ReadAllBytes($outputPath))) "redirected stdout is copied byte for byte"
    Write-Host "PASS: password on stdin and binary-safe transfer"

    $calls = New-Object 'System.Collections.Generic.List[string]'
    $passworded = New-Object 'System.Collections.Generic.List[string]'
    $copyFile = { param($source, $destination, $mode) $calls.Add("copy $destination $mode") }
    $overlay = {
        param($command, $usePassword, $inputPath)
        $calls.Add("overlay " + ($command -join " ") + $(if ($inputPath) { " <$inputPath" } else { "" }))
        if ($usePassword) { $passworded.Add($command[0]) }
    }
    Invoke-WorkerProvision -Configuration $configuration -OverlayPath "C:\assets\openhands-overlay" `
        -ProfilePath "C:\assets\profile-towerr.json" -CommonProfilePath "" -StatePath "" -CopyFile $copyFile -Overlay $overlay
    Invoke-WorkerActivation -Overlay $overlay
    $expected = @(
        "copy /usr/local/sbin/openhands-overlay 0755",
        "copy /etc/openhands/profile.json 0600",
        "overlay ca --vault-url https://vlt.h-cloud.io --email agent-worker@harke.me --item cf9ec766-c260-4e7d-abe0-3299745b57b4",
        "overlay secrets --vault-url https://vlt.h-cloud.io --email agent-worker@harke.me --crt-id 2924548c-ec74-4fd3-9181-b303cd574dbb --key-id a9e6c601-77b3-47b6-980d-493743b7d7da --api-id b9ba25a8-0b4f-45ef-9236-2504c2ba807c",
        "overlay github --pat-id 28226043-0a70-4d54-bfb8-592086a319c0",
        "overlay origin https://orc.ai.h-cloud.lan",
        "overlay enable",
        "overlay settings --file /etc/openhands/profile.json",
        "overlay verify")
    Assert-Equal ($expected -join " | ") ($calls -join " | ") "provisioning runs the overlay commands in order"
    Assert-Equal "ca secrets github settings" ($passworded -join " ") "only vault-backed commands receive the master password"

    $calls.Clear()
    Invoke-WorkerProvision -Configuration $configuration -OverlayPath "C:\assets\openhands-overlay" `
        -ProfilePath "C:\assets\profile-towerr.json" -CommonProfilePath "C:\assets\profile-common.json" -StatePath "" -CopyFile $copyFile -Overlay $overlay
    Invoke-WorkerActivation -Overlay $overlay -ProfilePaths (Get-WorkerGuestProfilePaths -CommonProfilePath "C:\assets\profile-common.json")
    Assert-Equal "copy /etc/openhands/profile-common.json 0600" $calls[1] "the common profile is staged before the host profile"
    Assert-Equal "copy /etc/openhands/profile.json 0600" $calls[2] "the host profile is staged after the common profile"
    Assert-True ($calls -contains "overlay settings --file /etc/openhands/profile-common.json --file /etc/openhands/profile.json") "activation layers the common profile under the host profile"

    $calls.Clear()
    Invoke-WorkerProvision -Configuration $configuration -OverlayPath "C:\assets\openhands-overlay" `
        -ProfilePath "C:\assets\profile-towerr.json" -CommonProfilePath "" -StatePath "C:\state.tar.gz" -CopyFile $copyFile -Overlay $overlay
    Assert-Equal "overlay state import <C:\state.tar.gz" $calls[$calls.Count - 1] "state import is the last step before activation"
    Write-Host "PASS: provisioning order"
}
finally {
    Remove-Item -Path Env:FAKE_WSL_ARGV, Env:FAKE_WSL_STDIN, Env:FAKE_WSL_EXIT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: setup.ps1"
