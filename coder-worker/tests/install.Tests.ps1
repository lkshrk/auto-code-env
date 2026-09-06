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
if (($source -replace '(?m)^\$ReleaseSigningKey = "[^"]*"$', '') -match '2375') {
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
if ($source -match '\$DefaultChecksumsSha256') {
    throw "install.ps1 must not pin a per-release checksums digest."
}
if ($source -notmatch '(?m)^\$ReleaseSigningKey = "(?<key>[A-Za-z0-9+/]+={0,2})"$') {
    throw "install.ps1 must embed the release signing key as a base64 SubjectPublicKeyInfo."
}
$releaseSigningKey = $Matches["key"]
foreach ($name in "Set-WslMirroredNetworking", "Test-DistributionName", "Test-WslDistributionRegistered",
    "Test-UbuntuRelease", "Test-Sha256Digest", "Test-WslVersionSupported", "Get-WslExecutablePath",
    "Get-FileSha256", "Get-StagedArtifact", "Get-DistributionInstallArguments",
    "Test-ProfileKeySecretShaped", "Test-ProfileValueSecretShaped", "Test-ProfileValue",
    "Read-CoderWorkerProfile", "Get-ChecksumMap", "Get-ReleaseAssetUri", "Test-ReleaseSignature",
    "Get-ReleaseChecksums", "Get-Artifact") {
    Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name $name)
}

$keyBytes = [Convert]::FromBase64String($releaseSigningKey)
$anchor = [Security.Cryptography.ECDsa]::Create()
try {
    $read = 0
    $anchor.ImportSubjectPublicKeyInfo($keyBytes, [ref]$read)
    Assert-Equal $keyBytes.Length $read "the embedded key is exactly one SubjectPublicKeyInfo"
    Assert-Equal 256 $anchor.KeySize "the embedded key is 256 bits"
    Assert-Equal "1.2.840.10045.3.1.7" $anchor.ExportParameters($false).Curve.Oid.Value "the embedded key is on P-256"
}
finally {
    $anchor.Dispose()
}
Write-Host "PASS: install.ps1 embeds a parseable P-256 release signing key"

function Assert-Signature {
    param([bool]$Expected, [byte[]]$Data, [byte[]]$Signature, [string]$PublicKey, [string]$Message)

    Assert-Equal $Expected (Test-ReleaseSignature -Data $Data -Signature $Signature -PublicKey $PublicKey) $Message
}

function New-TamperedCopy {
    param([byte[]]$Bytes, [int]$Index)

    $copy = [byte[]]::new($Bytes.Length)
    [Array]::Copy($Bytes, $copy, $Bytes.Length)
    $copy[$Index] = $copy[$Index] -bxor 0x01
    return $copy
}

# Produced once by openssl over the fixture below, private key destroyed: CI's PowerShell image has no openssl.
$vectorKey = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEOw5k+vIz2zSxHCFOywj+tCsM4hmokPDMoz/pEBeaoiOafWZAHYsum4zIm3+mQkUvTjfW/7VVO10XGlakEQrXNg=="
$vectorSignature = [Convert]::FromBase64String("MEUCIQDvwHCqSvh8lpfUbA+9EVYKNJ7K8ix4ZNBhiudGIx/NBQIgIUfHWtcXe5gyuutI8exfrgORRdgVAFunrZBTgKMVXWQ=")
$vectorPayload = [Text.Encoding]::ASCII.GetBytes((("a" * 64) + "  coder-worker-overlay`n" + ("b" * 64) + "  firewall.ps1`n"))

Assert-Signature $true $vectorPayload $vectorSignature $vectorKey "an openssl-produced DER signature verifies"
Assert-Signature $false (New-TamperedCopy -Bytes $vectorPayload -Index 70) $vectorSignature $vectorKey "a tampered payload is refused"
Assert-Signature $false $vectorPayload (New-TamperedCopy -Bytes $vectorSignature -Index 10) $vectorKey "a tampered signature is refused"
Assert-Signature $false $vectorPayload ([byte[]]@()) $vectorKey "an empty signature is refused"
Assert-Signature $false $vectorPayload ([Text.Encoding]::ASCII.GetBytes("not DER at all")) $vectorKey "a signature that is not DER is refused"
Assert-Signature $false $vectorPayload $vectorSignature[0..40] $vectorKey "a truncated signature is refused"
Assert-Signature $false ([byte[]]@()) $vectorSignature $vectorKey "an empty payload is refused"
Assert-Signature $false $vectorPayload $vectorSignature $releaseSigningKey "the embedded key refuses a foreign release's signature"

$foreign = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromValue("1.2.840.10045.3.1.7"))
try {
    $foreignSignature = $foreign.SignData($vectorPayload, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
}
finally {
    $foreign.Dispose()
}
Assert-Signature $false $vectorPayload $foreignSignature $vectorKey "a signature from a different key is refused"
Assert-ThrowsMessage { Test-ReleaseSignature -Data $vectorPayload -Signature $vectorSignature -PublicKey "not base64" } `
    "Base-64" "a corrupt embedded key aborts rather than silently failing closed"
Write-Host "PASS: release signature verification"

$openssl = Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $openssl) {
    Write-Host "SKIP: the openssl round trip needs openssl on PATH"
}
else {
    $signing = Join-Path ([IO.Path]::GetTempPath()) ("coder-worker-signing-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $signing | Out-Null
    try {
        $payloadPath = Join-Path $signing "checksums.txt"
        [IO.File]::WriteAllBytes($payloadPath, $vectorPayload)
        $publicKeys = @()
        $signatures = @()
        foreach ($index in 0, 1) {
            $keyPath = Join-Path $signing "throwaway-$index.pem"
            $derPath = Join-Path $signing "throwaway-$index.der"
            $signaturePath = Join-Path $signing "checksums-$index.sig"
            & $openssl.Path ecparam -name prime256v1 -genkey -noout -out $keyPath
            if ($LASTEXITCODE -ne 0) { throw "openssl could not generate a throwaway key." }
            & $openssl.Path pkey -in $keyPath -pubout -outform DER -out $derPath
            if ($LASTEXITCODE -ne 0) { throw "openssl could not export the throwaway public key." }
            & $openssl.Path dgst -sha256 -sign $keyPath -out $signaturePath $payloadPath
            if ($LASTEXITCODE -ne 0) { throw "openssl could not sign the fixture." }
            $publicKeys += [Convert]::ToBase64String([IO.File]::ReadAllBytes($derPath))
            $signatures += , [IO.File]::ReadAllBytes($signaturePath)
        }

        Assert-Signature $true $vectorPayload $signatures[0] $publicKeys[0] "a freshly signed fixture verifies"
        Assert-Signature $false $vectorPayload $signatures[1] $publicKeys[0] "a signature from the other throwaway key is refused"
        Assert-Signature $false (New-TamperedCopy -Bytes $vectorPayload -Index 0) $signatures[0] $publicKeys[0] `
            "a tampered fixture is refused"
        Assert-Signature $false $vectorPayload (New-TamperedCopy -Bytes $signatures[0] -Index 20) $publicKeys[0] `
            "a tampered fresh signature is refused"
        Write-Host "PASS: openssl signs what install.ps1 verifies"
    }
    finally {
        Remove-Item -LiteralPath $signing -Recurse -Force -ErrorAction SilentlyContinue
    }
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
$signer = $null
$stranger = $null
try {
    $ReleaseBaseUri = "https://example/download"
    $DefaultRelease = "coder-worker-v2.0.0"
    $stage = $fetch
    $script:downloads = 0
    $script:body = ("a" * 64) + "  coder-worker-overlay`n"
    $script:staged = $null
    $script:checksums = $null
    $script:requested = @()
    $script:signature = [byte[]]@()

    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing)
        $script:downloads++
        $script:requested += "$Uri"
        if ("$Uri".EndsWith(".sig")) {
            [IO.File]::WriteAllBytes($OutFile, $script:signature)
        }
        else {
            [IO.File]::WriteAllText($OutFile, $script:body)
        }
    }
    function Get-StagedArtifact {
        param($Label, $Path, $Uri, $Sha256, $Destination)
        $script:staged = [pscustomobject]@{ Label = $Label; Path = $Path; Uri = $Uri; Sha256 = $Sha256 }
        return $Destination
    }
    $stream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($script:body))
    try { $bodyDigest = Get-FileSha256 -Stream $stream } finally { $stream.Dispose() }

    $signer = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromValue("1.2.840.10045.3.1.7"))
    $stranger = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve]::CreateFromValue("1.2.840.10045.3.1.7"))
    $ReleaseSigningKey = [Convert]::ToBase64String($signer.ExportSubjectPublicKeyInfo())
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($script:body)
    $signedBody = $script:body
    $goodSignature = $signer.SignData($bodyBytes, [Security.Cryptography.HashAlgorithmName]::SHA256,
        [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
    $script:signature = $goodSignature

    $tag = $DefaultRelease
    $ChecksumsSha256 = ""
    $map = Get-ReleaseChecksums
    Assert-Equal 2 $script:downloads "checksums.txt and its signature are both downloaded"
    Assert-Equal "https://example/download/coder-worker-v2.0.0/checksums.txt" $script:requested[0] "checksums.txt comes from the pinned tag"
    Assert-Equal "https://example/download/coder-worker-v2.0.0/checksums.txt.sig" $script:requested[1] "the signature comes from the same tag"
    Assert-Equal ("a" * 64) $map["coder-worker-overlay"] "the overlay digest is read from checksums.txt"
    Get-ReleaseChecksums | Out-Null
    Assert-Equal 2 $script:downloads "a second call reuses the cached map"

    $script:checksums = $null
    $script:body = ("b" * 64) + "  coder-worker-overlay`n"
    Assert-ThrowsMessage { Get-ReleaseChecksums } "is not signed by the release signing key" `
        "a checksums.txt the signature does not cover is refused"
    $script:body = $signedBody
    foreach ($case in @(
            @{ Signature = [byte[]]@(); Message = "an empty signature is refused" },
            @{ Signature = [Text.Encoding]::ASCII.GetBytes("not DER at all"); Message = "a signature that is not DER is refused" },
            @{ Signature = $goodSignature[0..40]; Message = "a truncated signature is refused" },
            @{ Signature = $stranger.SignData($bodyBytes, [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence); Message = "a signature from another key is refused" }
        )) {
        $script:checksums = $null
        $script:signature = [byte[]]$case.Signature
        Assert-ThrowsMessage { Get-ReleaseChecksums } "is not signed by the release signing key" $case.Message
    }
    $script:signature = $goodSignature

    $script:checksums = $null
    $script:requested = @()
    $tag = "coder-worker-v9.9.9"
    Get-ReleaseChecksums | Out-Null
    Assert-Equal "https://example/download/coder-worker-v9.9.9/checksums.txt.sig" $script:requested[1] `
        "-ReleaseTag needs no digest, because the signing key is not per release"
    $tag = $DefaultRelease

    $script:checksums = $null
    $script:downloads = 0
    $script:signature = [byte[]]@()
    $ChecksumsSha256 = $bodyDigest
    Get-ReleaseChecksums | Out-Null
    Assert-Equal 1 $script:downloads "-ChecksumsSha256 pins the file by digest and fetches no signature"
    $script:checksums = $null
    $ChecksumsSha256 = "c" * 64
    Assert-ThrowsMessage { Get-ReleaseChecksums } "does not match the expected digest" "a wrong -ChecksumsSha256 is refused"
    $script:checksums = $null
    $script:downloads = 0
    $ChecksumsSha256 = "not a digest"
    Assert-ThrowsMessage { Get-ReleaseChecksums } "64-character hexadecimal" "a malformed -ChecksumsSha256 is refused"
    Assert-Equal 0 $script:downloads "a malformed -ChecksumsSha256 is refused before anything is fetched"
    $ChecksumsSha256 = ""
    $script:signature = $goodSignature
    Write-Host "PASS: checksums.txt is trusted only through the release signature or an operator-pinned digest"

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
    if ($null -ne $signer) { $signer.Dispose() }
    if ($null -ne $stranger) { $stranger.Dispose() }
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
