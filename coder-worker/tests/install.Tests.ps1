$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-ArgumentCall {
    param([string[]]$Expected, [string[]]$Actual, [string]$Message)

    Assert-Equal $Expected.Count $Actual.Count "$Message argument count"
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Expected[$index] $Actual[$index] "$Message argument $index"
    }
}

function Assert-ThrowsMessage {
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
        throw "$Name is missing."
    }

    return $function.Extent.Text
}

$scriptPath = Join-Path $PSScriptRoot (Join-Path ".." (Join-Path "windows" "install.ps1"))
$profilePath = Join-Path $PSScriptRoot (Join-Path ".." (Join-Path "hosts" "towerr.profile"))
$source = Get-Content -Raw $scriptPath
foreach ($required in '--no-launch', '--set-sparse', '--terminate', 'foreach \(\$pass in 1, 2\)',
    'coder-worker-overlay', 'install', '--profile', 'firewall\.ps1', 'keepalive\.ps1') {
    if ($source -notmatch $required) {
        throw "install.ps1 must contain $required."
    }
}
if ($source -match '2375') {
    throw "install.ps1 must never mention the plaintext docker port."
}
if ($source -notmatch '\$TlsPort = 2376') {
    throw "install.ps1 must pin the mutual-TLS port."
}
if ($source -match '(?m)^\s*\$DistroName\s*=\s*"') {
    throw "install.ps1 must take the distribution name from the host profile."
}
if ($source -notmatch '(?m)^\$DefaultRelease = "(?<tag>coder-worker-v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?)"$') {
    throw "install.ps1 must pin a well-formed default release tag."
}
$defaultRelease = $Matches["tag"]
if ($source -notmatch '(?m)^\$ReleaseBaseUri = "https://') {
    throw "install.ps1 must fetch release assets over HTTPS."
}
if ($source -notmatch '(?m)^\$DefaultChecksumsSha256 = "(?<digest>[0-9a-f]{64})"$') {
    throw "install.ps1 must embed the SHA-256 of its release's checksums.txt."
}
$defaultChecksumsSha256 = $Matches["digest"]
foreach ($name in "Set-WslMirroredNetworking", "Test-DistributionName", "Test-WslDistributionRegistered",
    "Test-UbuntuRelease", "Test-Sha256Digest", "Test-WslVersionSupported", "Get-WslExecutablePath",
    "Get-FileSha256", "Get-StagedArtifact", "Get-DistributionInstallArguments",
    "Test-ProfileKeySecretShaped", "Test-ProfileValueSecretShaped", "Test-ProfileValue",
    "Read-CoderWorkerProfile", "Get-ChecksumMap", "Get-ReleaseAssetUri",
    "Get-ReleaseChecksums", "Get-Artifact") {
    Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name $name)
}

Assert-Equal $true (Test-DistributionName -Name "coder-worker") "the default distribution name is valid"
Assert-Equal $false (Test-DistributionName -Name "") "an empty distribution name is refused"
Assert-Equal $false (Test-DistributionName -Name "coder worker") "a distribution name with a space is refused"
Assert-Equal $false (Test-DistributionName -Name "-coder") "a distribution name starting with a dash is refused"
Assert-Equal $false (Test-DistributionName -Name "..") "a traversing host profile name is refused"
Assert-Equal $true (Test-WslDistributionRegistered -Output @("Ubuntu", "coder-worker") -Name "coder-worker") "a registered distribution is found"
Assert-Equal $false (Test-WslDistributionRegistered -Output @("Ubuntu", "coder-worker-2") -Name "coder-worker") "a prefix match is not a registration"
Assert-Equal $true (Test-UbuntuRelease -Output @('ID=ubuntu', 'VERSION_ID="26.04"') -Version "26.04") "Ubuntu 26.04 is accepted"
Assert-Equal $false (Test-UbuntuRelease -Output @('ID=debian', 'VERSION_ID="26.04"') -Version "26.04") "Debian is refused"
Assert-Equal $false (Test-UbuntuRelease -Output @('ID=ubuntu', 'VERSION_ID="24.04"') -Version "26.04") "Ubuntu 24.04 is refused"
Assert-Equal $true (Test-WslVersionSupported -Output @("WSL version: 2.7.1")) "WSL 2.7.1 is supported"
Assert-Equal $false (Test-WslVersionSupported -Output @("WSL version: 2.4.4")) "WSL 2.4.4 is refused"
Write-Host "PASS: identity and version validation"

$digest = "a" * 64
Assert-Equal $true (Test-Sha256Digest -Output @("$digest  /root/coder-worker/coder-worker-overlay") -Expected $digest) "a matching in-distro digest is accepted"
Assert-Equal $true (Test-Sha256Digest -Output @("$digest  /root/coder-worker/coder-worker-overlay") -Expected $digest.ToUpperInvariant()) "digest comparison is case-insensitive"
Assert-Equal $false (Test-Sha256Digest -Output @((("b" * 64) + "  /root/coder-worker/coder-worker-overlay")) -Expected $digest) "a differing in-distro digest is refused"
Assert-Equal $false (Test-Sha256Digest -Output @("sha256sum: cannot open") -Expected $digest) "a missing digest is refused"
Write-Host "PASS: in-distro digest comparison"

Assert-ArgumentCall @("--install", "Ubuntu-26.04", "--name", "coder-worker", "--no-launch") `
    (Get-DistributionInstallArguments -Name "coder-worker" -Flavor "Ubuntu-26.04" -Location "" -RootfsPath "") `
    "the store install never launches the distribution"
Assert-ArgumentCall @("--install", "Ubuntu-26.04", "--name", "coder-worker", "--no-launch", "--location", "D:\wsl") `
    (Get-DistributionInstallArguments -Name "coder-worker" -Flavor "Ubuntu-26.04" -Location "D:\wsl" -RootfsPath "") `
    "the store install honours the location"
Assert-ArgumentCall @("--import", "coder-worker", "D:\wsl", "C:\rootfs.tar.gz", "--version", "2") `
    (Get-DistributionInstallArguments -Name "coder-worker" -Flavor "Ubuntu-26.04" -Location "D:\wsl" -RootfsPath "C:\rootfs.tar.gz") `
    "the fallback imports a root filesystem as WSL 2"
Assert-ThrowsMessage { Get-DistributionInstallArguments -Name "coder-worker" -Flavor "Ubuntu-26.04" -Location "" -RootfsPath "C:\rootfs.tar.gz" } `
    "Location is required" "the fallback refuses to import without a location"
Write-Host "PASS: distribution install arguments"

foreach ($key in "VAULT_PASSWORD", "GITHUB_TOKEN", "CLIENT_SECRET", "SIGNING_KEY", "KEY_MATERIAL",
    "API_KEY_ID", "MY_CREDENTIAL", "PRIVATE_THING", "APIKEY", "VAULT_PASSPHRASE") {
    Assert-Equal $true (Test-ProfileKeySecretShaped -Key $key) "'$key' is refused as a secret-shaped key"
}
foreach ($key in "DISTRO_NAME", "VAULT_URL", "VAULT_EMAIL", "VAULT_FOLDER", "DOCKER_PORT",
    "FIREWALL_REMOTE_ADDRESSES", "VAULT_ITEM_SERVER_KEY", "VAULT_ITEM_CA") {
    Assert-Equal $false (Test-ProfileKeySecretShaped -Key $key) "'$key' is an allowed profile key"
}
Assert-Equal $true (Test-ProfileValueSecretShaped -Value "-----BEGIN EC PRIVATE KEY-----") "PEM material is refused"
Assert-Equal $true (Test-ProfileValueSecretShaped -Value "ghp_0123456789") "a GitHub token prefix is refused"
Assert-Equal $true (Test-ProfileValueSecretShaped -Value ("A" * 40)) "a long opaque value is refused"
Assert-Equal $false (Test-ProfileValueSecretShaped -Value "coder-worker docker server key") "a vault item name is allowed"
Assert-Equal $false (Test-ProfileValueSecretShaped -Value "10.254.0.10,10.254.0.11,10.254.0.20,10.254.0.99") "the node address list is allowed"
Assert-Equal $false (Test-ProfileValueSecretShaped -Value "https://vlt.h-cloud.io") "a vault URL is allowed"
Assert-Equal $false (Test-ProfileValue -Key "DOCKER_PORT" -Value "2375") "the plaintext port is never a valid profile port"
Assert-Equal $false (Test-ProfileValue -Key "VAULT_URL" -Value "http://vlt.h-cloud.io") "a plain HTTP vault URL is refused"
Assert-Equal $false (Test-ProfileValue -Key "FIREWALL_REMOTE_ADDRESSES" -Value "Any") "an Any firewall source is refused"
Assert-Equal $true (Test-ProfileValue -Key "FIREWALL_REMOTE_ADDRESSES" -Value "10.254.0.10,10.254.0.11") "a node address list is accepted"
foreach ($bad in "999.999.999.999", "10.254.0.256", "10.254.0.10/33", "10.254.0.10/99", "10.254.0.10,300.1.1.1") {
    Assert-Equal $false (Test-ProfileValue -Key "FIREWALL_REMOTE_ADDRESSES" -Value $bad) "an out-of-range address is refused: $bad"
}
Write-Host "PASS: the host profile carries no credentials"

$committed = Read-CoderWorkerProfile -Lines ([string[]][IO.File]::ReadAllLines($profilePath))
Assert-Equal "coder-worker" $committed["DISTRO_NAME"] "the committed profile names the distribution"
Assert-Equal "Ubuntu-26.04" $committed["UBUNTU_DISTRIBUTION"] "the committed profile pins the Ubuntu flavour"
Assert-Equal "2376" $committed["DOCKER_PORT"] "the committed profile exposes only the mutual-TLS port"
Assert-Equal "Server" $committed["VAULT_FOLDER"] "the committed profile scopes vault lookups to one folder"
Assert-Equal "coder-worker docker ca" $committed["VAULT_ITEM_CA"] "the committed profile names the docker CA item"
Assert-Equal "10.254.0.10,10.254.0.11,10.254.0.20,10.254.0.99" $committed["FIREWALL_REMOTE_ADDRESSES"] "the committed profile lists the node addresses"

Assert-ThrowsMessage { Read-CoderWorkerProfile -Lines @("VAULT_PASSWORD=hunter2") } "names a secret" "a password key is refused"
Assert-ThrowsMessage { Read-CoderWorkerProfile -Lines @("DOCKER_HOSTNAME=towerr") } "unknown key" "an unknown key is refused"
Assert-ThrowsMessage { Read-CoderWorkerProfile -Lines @("DISTRO NAME=x") } "is not NAME=value" "a malformed line is refused"
Assert-ThrowsMessage { Read-CoderWorkerProfile -Lines @("DISTRO_NAME=a", "DISTRO_NAME=b") } "repeats" "a repeated key is refused"
Assert-ThrowsMessage { Read-CoderWorkerProfile -Lines @("VAULT_URL=-----BEGIN CERTIFICATE-----") } "looks like a credential" "PEM material in a value is refused"
Assert-ThrowsMessage { Read-CoderWorkerProfile -Lines @("DISTRO_NAME=coder-worker") } "is missing" "an incomplete profile is refused"
Write-Host "PASS: host profile parsing"

$map = Get-ChecksumMap -Lines @((("a" * 64) + "  coder-worker-overlay"), (("b" * 64) + " *firewall.ps1"), "")
Assert-Equal 2 $map.Count "both checksum lines are parsed"
Assert-Equal ("a" * 64) $map["coder-worker-overlay"] "the overlay digest is read"
Assert-Equal ("b" * 64) $map["firewall.ps1"] "a binary-mode digest is read"
Assert-ThrowsMessage { Get-ChecksumMap -Lines @("not a checksum line") } "is not a sha256sum line" "a malformed checksum line is refused"
Assert-ThrowsMessage { Get-ChecksumMap -Lines @((("a" * 64) + "  ../evil")) } "is not a sha256sum line" "a traversing asset name is refused"
Assert-ThrowsMessage { Get-ChecksumMap -Lines @((("a" * 63) + "  short")) } "is not a sha256sum line" "a short digest is refused"
Assert-ThrowsMessage { Get-ChecksumMap -Lines @((("a" * 64) + "  dup"), (("b" * 64) + "  dup")) } "more than once" "a duplicate asset name is refused"
Assert-ThrowsMessage { Get-ChecksumMap -Lines @() } "is empty" "an empty checksums file is refused"
Write-Host "PASS: checksums.txt parsing"

Assert-Equal "https://example/coder-worker-v1.2.3/checksums.txt" `
    (Get-ReleaseAssetUri -BaseUri "https://example" -Tag "coder-worker-v1.2.3" -Asset "checksums.txt") "a release asset URI is built from the pinned tag"
Assert-ThrowsMessage { Get-ReleaseAssetUri -BaseUri "https://example" -Tag "main" -Asset "checksums.txt" } `
    "is not a coder-worker release tag" "a branch name is not a release tag"
Assert-ThrowsMessage { Get-ReleaseAssetUri -BaseUri "https://example" -Tag "coder-worker-v1.2.3" -Asset "../../evil" } `
    "is not valid" "a traversing asset name is refused"
Get-ReleaseAssetUri -BaseUri "https://example" -Tag $defaultRelease -Asset "checksums.txt" | Out-Null
Write-Host "PASS: pinned release asset URIs"

$fetch = Join-Path ([IO.Path]::GetTempPath()) ("coder-worker-fetch-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $fetch | Out-Null
try {
    $ReleaseBaseUri = "https://example/download"
    $DefaultRelease = "coder-worker-v2.0.0"
    $stage = $fetch
    $script:downloads = 0
    $script:body = ("a" * 64) + "  coder-worker-overlay`n"
    $script:staged = $null
    $script:checksums = $null
    $script:requested = ""

    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing)
        $script:downloads++
        $script:requested = "$Uri"
        [IO.File]::WriteAllText($OutFile, $script:body)
    }
    function Get-StagedArtifact {
        param($Label, $Path, $Uri, $Sha256, $Destination)
        $script:staged = [pscustomobject]@{ Label = $Label; Path = $Path; Uri = $Uri; Sha256 = $Sha256 }
        return $Destination
    }
    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($script:body))
    try { $bodyDigest = Get-FileSha256 -Stream $stream } finally { $stream.Dispose() }

    $tag = $DefaultRelease
    $ChecksumsSha256 = ""
    $DefaultChecksumsSha256 = $bodyDigest
    $map = Get-ReleaseChecksums
    Assert-Equal 1 $script:downloads "checksums.txt is downloaded once"
    Assert-Equal "https://example/download/coder-worker-v2.0.0/checksums.txt" $script:requested "checksums.txt comes from the pinned tag"
    Assert-Equal ("a" * 64) $map["coder-worker-overlay"] "the overlay digest is read from checksums.txt"
    Get-ReleaseChecksums | Out-Null
    Assert-Equal 1 $script:downloads "a second call reuses the cached map"

    $script:checksums = $null
    $DefaultChecksumsSha256 = "b" * 64
    Assert-ThrowsMessage { Get-ReleaseChecksums } "does not match the expected digest" `
        "a checksums.txt that fails the embedded digest is refused"
    $script:checksums = $null
    $DefaultChecksumsSha256 = "not a digest"
    Assert-ThrowsMessage { Get-ReleaseChecksums } "64-character hexadecimal" "a malformed embedded digest is refused"
    $script:checksums = $null
    $DefaultChecksumsSha256 = $bodyDigest
    $ChecksumsSha256 = "c" * 64
    Assert-ThrowsMessage { Get-ReleaseChecksums } "does not match the expected digest" `
        "an explicit ChecksumsSha256 overrides the embedded one"
    $script:checksums = $null
    $ChecksumsSha256 = ""
    $tag = "coder-worker-v9.9.9"
    Assert-ThrowsMessage { Get-ReleaseChecksums } "ChecksumsSha256 is required with -ReleaseTag" `
        "another release tag may not reuse the embedded digest"
    Write-Host "PASS: checksums.txt is never trusted without a digest known before the download"

    $tag = $DefaultRelease
    $script:checksums = $null
    Get-Artifact -Label "Overlay" -Asset "coder-worker-overlay" -Destination (Join-Path $fetch "out") | Out-Null
    Assert-Equal "https://example/download/coder-worker-v2.0.0/coder-worker-overlay" $script:staged.Uri "the artifact URI is built from the pinned tag"
    Assert-Equal ("a" * 64) $script:staged.Sha256 "the artifact digest comes from checksums.txt"
    Assert-ThrowsMessage { Get-Artifact -Label "Firewall" -Asset "firewall.ps1" -Destination (Join-Path $fetch "out") } `
        "has no entry for 'firewall.ps1'" "an artifact missing from checksums.txt is refused"

    $script:staged = $null
    $script:downloads = 0
    Get-Artifact -Label "Overlay" -Asset "coder-worker-overlay" -Path "C:\local\overlay" -Sha256 ("e" * 64) `
        -Destination (Join-Path $fetch "out") | Out-Null
    Assert-Equal "C:\local\overlay" $script:staged.Path "a local path is passed through untouched"
    Assert-Equal ("e" * 64) $script:staged.Sha256 "a local path keeps its explicit checksum"
    Assert-Equal 0 $script:downloads "a local path never downloads checksums.txt"
    Write-Host "PASS: release artifacts resolve to a pinned URI and a checksums.txt digest"
}
finally {
    Remove-Item -LiteralPath $fetch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    Remove-Item -Path Function:\Get-StagedArtifact -ErrorAction SilentlyContinue
}
Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name "Get-StagedArtifact")

$work = Join-Path ([IO.Path]::GetTempPath()) ("coder-worker-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $artifact = Join-Path $work "coder-worker-overlay"
    Set-Content -LiteralPath $artifact -Value "#!/bin/bash`n" -NoNewline
    $stream = [IO.File]::Open($artifact, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $expected = Get-FileSha256 -Stream $stream
    }
    finally {
        $stream.Dispose()
    }

    Assert-ThrowsMessage { Get-StagedArtifact -Label "Overlay" -Sha256 $expected -Destination (Join-Path $work "a") } `
        "exactly one of OverlayPath or OverlayUri" "a missing source is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "Overlay" -Path $artifact -Uri "https://example/coder-worker-overlay" -Sha256 $expected -Destination (Join-Path $work "b") } `
        "exactly one of OverlayPath or OverlayUri" "two sources are refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "Overlay" -Path $artifact -Sha256 "" -Destination (Join-Path $work "c") } `
        "must be a 64-character hexadecimal" "an empty checksum is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "Overlay" -Path $artifact -Sha256 "abc" -Destination (Join-Path $work "d") } `
        "must be a 64-character hexadecimal" "a short checksum is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "Overlay" -Path $artifact -Sha256 ("f" * 64) -Destination (Join-Path $work "e") } `
        "SHA-256 does not match" "a wrong checksum is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "Overlay" -Uri "http://example/coder-worker-overlay" -Sha256 $expected -Destination (Join-Path $work "f") } `
        "must be an absolute HTTPS URI" "a plain HTTP source is refused"

    $staged = Get-StagedArtifact -Label "Overlay" -Path $artifact -Sha256 $expected -Destination (Join-Path $work "g")
    Assert-Equal (Join-Path $work "g") $staged "a matching artifact is staged"
    Write-Host "PASS: artifact staging refuses anything but a checksum match"

    $configPath = Join-Path $work ".wslconfig"
    $result = Set-WslMirroredNetworking -Path $configPath
    Assert-Equal $true $result.Changed "a missing .wslconfig is created"
    Assert-Equal "[wsl2]`nnetworkingMode=mirrored`ndnsTunneling=true`n" ([IO.File]::ReadAllText($configPath)) "the created .wslconfig mirrors networking"
    $result = Set-WslMirroredNetworking -Path $configPath
    Assert-Equal $false $result.Changed "an already mirrored .wslconfig is left alone"

    [IO.File]::WriteAllText($configPath, "[wsl2]`nnetworkingMode=nat`nmemory=8GB`n")
    $result = Set-WslMirroredNetworking -Path $configPath
    Assert-Equal $true $result.Changed "a nat .wslconfig is reconciled"
    Assert-Equal "[wsl2]`nnetworkingMode=mirrored`nmemory=8GB`ndnsTunneling=true`n" ([IO.File]::ReadAllText($configPath)) "operator settings survive reconciliation"
    Write-Host "PASS: mirrored networking reconciliation"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
