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

$scriptPath = Join-Path $PSScriptRoot "..\windows\install.ps1"
$source = Get-Content -Raw $scriptPath
foreach ($required in '\$DistroName = "coder-worker"', '--no-launch', '--set-sparse', '--terminate', 'foreach \(\$pass in 1, 2\)') {
    if ($source -notmatch $required) {
        throw "install.ps1 must contain $required."
    }
}
if ($source -match '2375') {
    throw "install.ps1 must never mention the plaintext docker port."
}
foreach ($name in "Set-WslMirroredNetworking", "Test-DistributionName", "Test-WslDistributionRegistered",
    "Test-UbuntuRelease", "Test-Sha256Digest", "Test-WslVersionSupported", "Get-WslExecutablePath",
    "Get-FileSha256", "Get-StagedArtifact", "Get-DistributionInstallArguments") {
    Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name $name)
}

Assert-Equal $true (Test-DistributionName -Name "coder-worker") "the default distribution name is valid"
Assert-Equal $false (Test-DistributionName -Name "") "an empty distribution name is refused"
Assert-Equal $false (Test-DistributionName -Name "coder worker") "a distribution name with a space is refused"
Assert-Equal $false (Test-DistributionName -Name "-coder") "a distribution name starting with a dash is refused"
Assert-Equal $true (Test-WslDistributionRegistered -Output @("Ubuntu", "coder-worker") -Name "coder-worker") "a registered distribution is found"
Assert-Equal $false (Test-WslDistributionRegistered -Output @("Ubuntu", "coder-worker-2") -Name "coder-worker") "a prefix match is not a registration"
Assert-Equal $true (Test-UbuntuRelease -Output @('ID=ubuntu', 'VERSION_ID="26.04"') -Version "26.04") "Ubuntu 26.04 is accepted"
Assert-Equal $false (Test-UbuntuRelease -Output @('ID=debian', 'VERSION_ID="26.04"') -Version "26.04") "Debian is refused"
Assert-Equal $false (Test-UbuntuRelease -Output @('ID=ubuntu', 'VERSION_ID="24.04"') -Version "26.04") "Ubuntu 24.04 is refused"
Assert-Equal $true (Test-WslVersionSupported -Output @("WSL version: 2.7.1")) "WSL 2.7.1 is supported"
Assert-Equal $false (Test-WslVersionSupported -Output @("WSL version: 2.4.4")) "WSL 2.4.4 is refused"
Write-Host "PASS: identity and version validation"

$digest = "a" * 64
Assert-Equal $true (Test-Sha256Digest -Output @("$digest  /root/coder-worker/setup.sh") -Expected $digest) "a matching in-distro digest is accepted"
Assert-Equal $true (Test-Sha256Digest -Output @("$digest  /root/coder-worker/setup.sh") -Expected $digest.ToUpperInvariant()) "digest comparison is case-insensitive"
Assert-Equal $false (Test-Sha256Digest -Output @(("b" * 64) + "  /root/coder-worker/setup.sh") -Expected $digest) "a differing in-distro digest is refused"
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

$work = Join-Path ([IO.Path]::GetTempPath()) ("coder-worker-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $source = Join-Path $work "setup.sh"
    Set-Content -LiteralPath $source -Value "#!/bin/bash`n" -NoNewline
    $stream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $expected = Get-FileSha256 -Stream $stream
    }
    finally {
        $stream.Dispose()
    }

    Assert-ThrowsMessage { Get-StagedArtifact -Label "SetupScript" -Sha256 $expected -Destination (Join-Path $work "a") } `
        "exactly one of SetupScriptPath or SetupScriptUri" "a missing source is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "SetupScript" -Path $source -Uri "https://example/setup.sh" -Sha256 $expected -Destination (Join-Path $work "b") } `
        "exactly one of SetupScriptPath or SetupScriptUri" "two sources are refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "SetupScript" -Path $source -Sha256 "" -Destination (Join-Path $work "c") } `
        "must be a 64-character hexadecimal" "an empty checksum is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "SetupScript" -Path $source -Sha256 "abc" -Destination (Join-Path $work "d") } `
        "must be a 64-character hexadecimal" "a short checksum is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "SetupScript" -Path $source -Sha256 ("f" * 64) -Destination (Join-Path $work "e") } `
        "SHA-256 does not match" "a wrong checksum is refused"
    Assert-ThrowsMessage { Get-StagedArtifact -Label "SetupScript" -Uri "http://example/setup.sh" -Sha256 $expected -Destination (Join-Path $work "f") } `
        "must be an absolute HTTPS URI" "a plain HTTP source is refused"

    $staged = Get-StagedArtifact -Label "SetupScript" -Path $source -Sha256 $expected -Destination (Join-Path $work "g")
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
