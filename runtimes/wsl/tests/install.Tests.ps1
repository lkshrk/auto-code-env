$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Match {
    param([string]$Pattern, [string]$Actual, [string]$Message = "Expected pattern was not found")

    if ($Actual -notmatch $Pattern) {
        throw "$Message. Pattern '$Pattern' was not found."
    }
}

function Assert-NotMatch {
    param([string]$Pattern, [string]$Actual, [string]$Message = "Unexpected pattern was found")

    if ($Actual -match $Pattern) {
        throw "$Message. Pattern '$Pattern' was found."
    }
}

function Assert-ArgumentCall {
    param([string[]]$Expected, [string[]]$Actual, [string]$Message)

    Assert-Equal $Expected.Count $Actual.Count "$Message argument count"
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        Assert-Equal $Expected[$index] $Actual[$index] "$Message argument $index"
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)

    try {
        & $Action
    }
    catch {
        return
    }

    throw "$Message. Expected an exception."
}

function Assert-ThrowsMessage {
    param([scriptblock]$Action, [string[]]$Patterns, [string]$Message)

    try {
        & $Action
    }
    catch {
        foreach ($pattern in $Patterns) {
            if ($_.Exception.Message -notmatch $pattern) {
                throw "$Message. Pattern '$pattern' was not found in '$($_.Exception.Message)'."
            }
        }
        return
    }

    throw "$Message. Expected an exception."
}

function Import-InstallFunction {
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

function New-FakeWslExecutable {
    param([string]$Root)

    $path = Join-Path $Root "fake-wsl"
    [System.IO.File]::WriteAllText($path, @'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_WSL_LOG"
printf '%s\0' "$#" >> "$FAKE_WSL_ARGV_LOG"
for argument in "$@"; do
    printf '%s\0' "$argument" >> "$FAKE_WSL_ARGV_LOG"
done

if [ "$1" = "--list" ] && [ "$2" = "--quiet" ]; then
    count=0
    if [ -f "$FAKE_WSL_LIST_COUNT" ]; then
        count=$(cat "$FAKE_WSL_LIST_COUNT")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_WSL_LIST_COUNT"
    if [ "$count" -eq 1 ] && [ "$FAKE_WSL_EMPTY_INITIAL_LIST" = "1" ]; then
        exit "${FAKE_WSL_LIST_EXIT:-0}"
    elif [ "$count" -eq 1 ]; then
        printf '%s\n' "$FAKE_WSL_LIST_BEFORE"
    else
        printf '%s\n' "$FAKE_WSL_LIST_AFTER"
    fi
    exit "${FAKE_WSL_LIST_EXIT:-0}"
fi

if [ "$1" = "--install" ]; then
    if [ "$FAKE_WSL_REQUIRE_STAGED_IMAGE" = "1" ]; then
        case "$3" in
            */openhands-worker-*) test -f "$3" || exit 98 ;;
            *) exit 98 ;;
        esac
    fi
    exit "${FAKE_WSL_INSTALL_EXIT:-0}"
fi

if [ "$1" = "--distribution" ] && [ "$3" = "--user" ] && [ "$4" = "root" ] && [ "$5" = "--exec" ] && [ "$6" = "id" ] && [ "$7" = "-u" ]; then
    if [ "$FAKE_WSL_ID_NUL" = "1" ]; then
        printf '%s\n' "$FAKE_WSL_ID" | awk '{ for (i = 1; i <= length($0); i++) { printf "%s%c", substr($0, i, 1), 0 }; printf "\n%c", 0 }'
    else
        printf '%s\n' "$FAKE_WSL_ID"
    fi
    exit "${FAKE_WSL_ID_EXIT:-0}"
fi

if [ "$1" = "--distribution" ] && [ "$3" = "--user" ] && [ "$4" = "root" ] && [ "$5" = "--exec" ] && [ "$6" = "cat" ] && [ "$7" = "/etc/os-release" ]; then
    if [ "$FAKE_WSL_RELEASE_NUL" = "1" ]; then
        printf '%s\n' "$FAKE_WSL_RELEASE" | awk '{ for (i = 1; i <= length($0); i++) { printf "%s%c", substr($0, i, 1), 0 }; printf "\n%c", 0 }'
    else
        printf '%s\n' "$FAKE_WSL_RELEASE"
    fi
    exit "${FAKE_WSL_RELEASE_EXIT:-0}"
fi

if [ "$1" = "--terminate" ]; then
    exit "${FAKE_WSL_TERMINATE_EXIT:-0}"
fi


exit 99
'@, [System.Text.UTF8Encoding]::new($false))
    & chmod +x $path
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to make fake WSL executable."
    }

    return $path
}

function Set-FakeWslScenario {
    param(
        [string]$Root,
        [string]$Before = "",
        [string]$After = "",
        [int]$ListExit = 0,
        [int]$InstallExit = 0,
        [bool]$EmptyInitialList = $false,
        [string]$Id = "0",
        [string]$Release = "ID=ubuntu`nVERSION_ID=`"26.04`"",
        [int]$IdExit = 0,
        [int]$ReleaseExit = 0,
        [int]$TerminateExit = 0,
        [bool]$NulId = $false,
        [bool]$NulRelease = $false
    )

    $env:FAKE_WSL_LOG = Join-Path $Root "fake-wsl.log"
    $env:FAKE_WSL_ARGV_LOG = Join-Path $Root "fake-wsl.argv"
    $env:FAKE_WSL_LIST_COUNT = Join-Path $Root "fake-wsl.list-count"
    [System.IO.File]::WriteAllText($env:FAKE_WSL_LOG, "", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllBytes($env:FAKE_WSL_ARGV_LOG, [byte[]]@())
    Remove-Item -LiteralPath $env:FAKE_WSL_LIST_COUNT -Force -ErrorAction SilentlyContinue
    $env:FAKE_WSL_LIST_BEFORE = $Before
    $env:FAKE_WSL_LIST_AFTER = $After
    $env:FAKE_WSL_LIST_EXIT = "$ListExit"
    $env:FAKE_WSL_INSTALL_EXIT = "$InstallExit"
    $env:FAKE_WSL_EMPTY_INITIAL_LIST = if ($EmptyInitialList) { "1" } else { "0" }
    $env:FAKE_WSL_ID = $Id
    $env:FAKE_WSL_RELEASE = $Release
    $env:FAKE_WSL_ID_EXIT = "$IdExit"
    $env:FAKE_WSL_RELEASE_EXIT = "$ReleaseExit"
    $env:FAKE_WSL_TERMINATE_EXIT = "$TerminateExit"
    $env:FAKE_WSL_ID_NUL = if ($NulId) { "1" } else { "0" }
    $env:FAKE_WSL_RELEASE_NUL = if ($NulRelease) { "1" } else { "0" }
    $env:FAKE_WSL_REQUIRE_STAGED_IMAGE = "0"
}

function Get-FakeWslCalls {
    return [System.IO.File]::ReadAllText($env:FAKE_WSL_LOG)
}

function Get-FakeWslArgumentCalls {
    $parts = ([System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($env:FAKE_WSL_ARGV_LOG))).Split([char]0)
    $calls = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    while ($index -lt $parts.Length - 1) {
        $count = [int]$parts[$index]
        $index++
        $arguments = New-Object 'System.Collections.Generic.List[string]'
        for ($argumentIndex = 0; $argumentIndex -lt $count; $argumentIndex++) {
            $arguments.Add($parts[$index])
            $index++
        }
        $calls.Add([string[]]$arguments)
    }
    return [object[]]$calls
}

function Invoke-ThrowingTerminateWsl {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$WslArguments)

    if ($WslArguments[0] -eq "--terminate") {
        throw "Simulated termination exception."
    }

    & $script:FakeWslPath @WslArguments
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wsl-install-tests-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $installPath = Join-Path $PSScriptRoot ".." "install.ps1"
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Set-WslMirroredNetworking")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-WslDistributionRegistered")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslArtifactArchitecture")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslImageSha256")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Resolve-WslImage")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Install-WslDistribution")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslExecutablePath")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-WslVersionSupported")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Restore-WslConfig")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-UbuntuRelease")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Assert-WslDistributionIdentity")))

    Assert-Equal "C:\Windows\System32\wsl.exe" (Get-WslExecutablePath -WindowsDirectory "C:\Windows" -Is64BitProcess $true -Is64BitOperatingSystem $true) "64-bit process WSL path"
    Assert-Equal "C:\Windows\Sysnative\wsl.exe" (Get-WslExecutablePath -WindowsDirectory "C:\Windows" -Is64BitProcess $false -Is64BitOperatingSystem $true) "32-bit process WSL path"
    Assert-Equal "C:\Windows\System32\wsl.exe" (Get-WslExecutablePath -WindowsDirectory "C:\Windows" -Is64BitProcess $false -Is64BitOperatingSystem $false) "32-bit OS WSL path"

    Assert-Equal $true (Test-WslVersionSupported -Output @("WSL version: 2.7.0", "Kernel version: 6.6")) "WSL 2.7.0 should be supported"
    Assert-Equal $false (Test-WslVersionSupported -Output @("WSL version: 2.6.9")) "WSL 2.6.9 should be rejected"
    Assert-Equal $false (Test-WslVersionSupported -Output @("WSL version: unknown")) "malformed WSL version should be rejected"
    Assert-Equal $true (Test-WslVersionSupported -Output @("WSL-Version: 2.7.10.0", "Kernel-Version: 6.6")) "localized WSL 2.7.10.0 should be supported"
    $nulSeparatedVersion = [string]::Join([char]0, [char[]]"WSL version: 2.7.0")
    Assert-Equal $true (Test-WslVersionSupported -Output @($nulSeparatedVersion)) "NUL-separated WSL 2.7.0 should be supported"


    $registered = @("docker-desktop", "openhands-worker")
    Assert-Equal $true (Test-WslDistributionRegistered -Output $registered -Name "openhands-worker") "exact registered distribution should be found"
    Assert-Equal $false (Test-WslDistributionRegistered -Output @("openhands-worker-old") -Name "openhands-worker") "similarly prefixed distribution should be rejected"
    Assert-Equal $false (Test-WslDistributionRegistered -Output @("Ubuntu 26.04 LTS (openhands-worker)") -Name "openhands-worker") "friendly names should not register the target"
    $nulSeparatedRegistered = [string]::Join([char]0, [char[]]"openhands-worker")
    Assert-Equal $true (Test-WslDistributionRegistered -Output @($nulSeparatedRegistered) -Name "openhands-worker") "NUL-separated registered distribution should be found"
    Assert-Equal $false (Test-WslDistributionRegistered -Output $null -Name "openhands-worker") "empty registered distribution output should not find the target"

    Assert-Equal $true (Test-UbuntuRelease -Output @("NAME=Ubuntu", "ID=ubuntu", "VERSION_ID=`"26.04`"") -Version "26.04") "Ubuntu 26.04 release should be accepted"
    Assert-Equal $false (Test-UbuntuRelease -Output @("ID=Ubuntu", "VERSION_ID=26.04") -Version "26.04") "case-variant Ubuntu ID should be rejected"
    Assert-Equal $false (Test-UbuntuRelease -Output @("ID=debian", "VERSION_ID=26.04") -Version "26.04") "wrong Ubuntu ID should be rejected"
    Assert-Equal $false (Test-UbuntuRelease -Output @("ID=ubuntu", "ID=debian", "VERSION_ID=26.04") -Version "26.04") "conflicting Ubuntu IDs should be rejected"
    Assert-Equal $false (Test-UbuntuRelease -Output @("ID=ubuntu", "VERSION_ID=26.04", "VERSION_ID=24.04") -Version "26.04") "duplicate Ubuntu versions should be rejected"
    Assert-Equal $false (Test-UbuntuRelease -Output @("ID=ubuntu", "VERSION_ID=26.04.1") -Version "26.04") "wrong Ubuntu release should be rejected"
    $nulSeparatedRelease = [string]::Join([char]0, [char[]]"ID=ubuntu`nVERSION_ID=26.04")
    Assert-Equal $true (Test-UbuntuRelease -Output @($nulSeparatedRelease) -Version "26.04") "NUL-separated Ubuntu release should be accepted"

    $fakeWslPath = New-FakeWslExecutable -Root $testRoot
    $script:FakeWslPath = $fakeWslPath
    Set-FakeWslScenario -Root $testRoot -NulId $true -NulRelease $true
    Assert-WslDistributionIdentity -WslPath $fakeWslPath -Name "openhands-worker"
    Assert-Equal "--distribution openhands-worker --user root --exec id -u`n--distribution openhands-worker --user root --exec cat /etc/os-release`n--terminate openhands-worker`n" (Get-FakeWslCalls) "identity checks should run as root and terminate only the target"

    Set-FakeWslScenario -Root $testRoot -Id "1000"
    Assert-Throws { Assert-WslDistributionIdentity -WslPath $fakeWslPath -Name "openhands-worker" } "non-root identity should fail"
    Assert-Equal "--distribution openhands-worker --user root --exec id -u`n--terminate openhands-worker`n" (Get-FakeWslCalls) "non-root identity should still terminate the target"

    Set-FakeWslScenario -Root $testRoot -Release "ID=ubuntu`nVERSION_ID=24.04"
    Assert-Throws { Assert-WslDistributionIdentity -WslPath $fakeWslPath -Name "openhands-worker" } "wrong release should fail"
    Assert-Equal "--distribution openhands-worker --user root --exec id -u`n--distribution openhands-worker --user root --exec cat /etc/os-release`n--terminate openhands-worker`n" (Get-FakeWslCalls) "wrong release should still terminate the target"

    Set-FakeWslScenario -Root $testRoot -IdExit 1
    Assert-Throws { Assert-WslDistributionIdentity -WslPath $fakeWslPath -Name "openhands-worker" } "nonzero root check should fail"
    Assert-Equal "--distribution openhands-worker --user root --exec id -u`n--terminate openhands-worker`n" (Get-FakeWslCalls) "failed root check should still terminate the target"

    Set-FakeWslScenario -Root $testRoot -ReleaseExit 1
    Assert-Throws { Assert-WslDistributionIdentity -WslPath $fakeWslPath -Name "openhands-worker" } "nonzero release check should fail"
    Assert-Equal "--distribution openhands-worker --user root --exec id -u`n--distribution openhands-worker --user root --exec cat /etc/os-release`n--terminate openhands-worker`n" (Get-FakeWslCalls) "failed release check should still terminate the target"

    Set-FakeWslScenario -Root $testRoot -TerminateExit 1
    Assert-Throws { Assert-WslDistributionIdentity -WslPath $fakeWslPath -Name "openhands-worker" } "termination failure should fail"
    Assert-Equal "--distribution openhands-worker --user root --exec id -u`n--distribution openhands-worker --user root --exec cat /etc/os-release`n--terminate openhands-worker`n" (Get-FakeWslCalls) "termination failure should still attempt only the target"

    Set-FakeWslScenario -Root $testRoot -IdExit 1 -TerminateExit 1
    Assert-ThrowsMessage -Action { Assert-WslDistributionIdentity -WslPath $fakeWslPath -Name "openhands-worker" } -Patterns @("root access", "terminate") -Message "identity and termination failures should both be reported"
    Assert-Equal "--distribution openhands-worker --user root --exec id -u`n--terminate openhands-worker`n" (Get-FakeWslCalls) "combined failure should still terminate only the target"

    Set-FakeWslScenario -Root $testRoot -IdExit 1
    Assert-ThrowsMessage -Action { Assert-WslDistributionIdentity -WslPath "Invoke-ThrowingTerminateWsl" -Name "openhands-worker" } -Patterns @("root access", "Simulated termination exception") -Message "identity and thrown termination failures should both be reported"

    Set-FakeWslScenario -Root $testRoot
    Assert-ThrowsMessage -Action { Assert-WslDistributionIdentity -WslPath "Invoke-ThrowingTerminateWsl" -Name "openhands-worker" } -Patterns @("Simulated termination exception") -Message "thrown termination failure should be fatal after a successful identity check"
    Assert-Equal "amd64" (Get-WslArtifactArchitecture -Architecture "AMD64") "AMD64 artifact architecture"
    Assert-Equal "arm64" (Get-WslArtifactArchitecture -Architecture "ARM64") "ARM64 artifact architecture"
    Assert-Equal "amd64" (Get-WslArtifactArchitecture -Architecture "ARM64" -Wow64Architecture "AMD64") "WOW64 architecture should take precedence"
    Assert-Equal "arm64" (Get-WslArtifactArchitecture -Architecture "ARM64" -Wow64Architecture "") "empty WOW64 architecture should fall back"
    Assert-Equal "arm64" (Get-WslArtifactArchitecture -Architecture "" -Wow64Architecture "" -RuntimeArchitecture "ARM64") "runtime architecture should be the final fallback"
    Assert-Throws { Get-WslArtifactArchitecture -Architecture "x86" } "unsupported architecture should fail"

    $imagePath = Join-Path $testRoot "openhands-worker-1.2.3-amd64.wsl"
    [System.IO.File]::WriteAllText($imagePath, "image", [System.Text.UTF8Encoding]::new($false))
    $imageHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash
    $localImage = Resolve-WslImage -ImagePath $imagePath -ImageSha256 $imageHash -Architecture "AMD64"
    Assert-Match 'openhands-worker-[0-9a-f]+$' $localImage.TemporaryDirectory "local image should use an installer-owned temporary directory"
    Assert-NotMatch ([regex]::Escape($imagePath)) $localImage.Path "local image should be staged"
    Assert-Equal $true $localImage.Stream.CanRead "staged image stream should remain open"
    if ($env:OS -eq "Windows_NT") {
        Assert-Throws { [System.IO.File]::Open($localImage.Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read) } "staged image handle should deny writers"
    }
    $localImage.Dispose()
    Remove-Item -LiteralPath $localImage.TemporaryDirectory -Recurse -Force
    $lowercaseImage = Resolve-WslImage -ImagePath $imagePath -ImageSha256 $imageHash.ToLowerInvariant() -Architecture "AMD64"
    $lowercaseImage.Dispose()
    Remove-Item -LiteralPath $lowercaseImage.TemporaryDirectory -Recurse -Force
    function Invoke-WebRequest {
        param([Uri]$Uri, [string]$OutFile, [switch]$UseBasicParsing)

        $script:DownloadedImageUri = $Uri.AbsoluteUri
        [System.IO.File]::WriteAllText($OutFile, "image", [System.Text.UTF8Encoding]::new($false))
    }
    $downloadedImage = Resolve-WslImage -ImageUri "https://example.invalid/openhands-worker-1.2.3-amd64.wsl" -ImageSha256 $imageHash -Architecture "AMD64"
    Assert-Match 'openhands-worker-[0-9a-f]+$' $downloadedImage.TemporaryDirectory "HTTPS image should use an installer-owned temporary directory"
    Assert-Equal $true (Test-Path -LiteralPath $downloadedImage.Path -PathType Leaf) "HTTPS image should download"
    $downloadedImage.Dispose()
    Remove-Item -LiteralPath $downloadedImage.TemporaryDirectory -Recurse -Force
    Assert-Throws { Resolve-WslImage -ImagePath $imagePath -ImageUri "https://example.invalid/openhands-worker-1.2.3-amd64.wsl" -ImageSha256 $imageHash -Architecture "AMD64" } "both artifact sources should fail"
    Assert-Throws { Resolve-WslImage -ImageSha256 $imageHash -Architecture "AMD64" } "missing artifact source should fail"
    Assert-Throws { Resolve-WslImage -ImagePath $imagePath -ImageSha256 "not-a-hash" -Architecture "AMD64" } "invalid image hash should fail"
    Assert-Throws { Resolve-WslImage -ImageUri "http://example.invalid/openhands-worker-1.2.3-amd64.wsl" -ImageSha256 $imageHash -Architecture "AMD64" } "non-HTTPS image URI should fail"
    $temporaryImagesBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "openhands-worker-*" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    Assert-Throws { Resolve-WslImage -ImagePath $imagePath -ImageSha256 ("0" * 64) -Architecture "AMD64" } "wrong image hash should fail"
    $temporaryImagesAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "openhands-worker-*" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    Assert-Equal ($temporaryImagesBefore -join "`n") ($temporaryImagesAfter -join "`n") "failed image resolution should clean its temporary directory"
    Assert-Throws { Resolve-WslImage -ImagePath $imagePath -ImageSha256 $imageHash -Architecture "ARM64" } "wrong image architecture should fail"

    Set-FakeWslScenario -Root $testRoot -Before "openhands-worker"
    Assert-Equal $false (Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImagePath $imagePath -ImageSha256 "not-a-hash" -Architecture "AMD64") "existing target should be a no-op before artifact validation"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "existing target should only be listed"

    Set-FakeWslScenario -Root $testRoot -Before "openhands-worker"
    Assert-Equal $false (Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker") "existing target should not require artifact arguments"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "existing target should not resolve an artifact"

    Set-FakeWslScenario -Root $testRoot
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImagePath $imagePath -ImageSha256 ("0" * 64) -Architecture "AMD64" } "wrong hash should fail before import"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "wrong hash should not invoke WSL import"

    Set-FakeWslScenario -Root $testRoot -Before "docker-desktop" -After "docker-desktop`nopenhands-worker"
    $env:FAKE_WSL_REQUIRE_STAGED_IMAGE = "1"
    $spacedTemporaryRoot = Join-Path $testRoot "temporary images"
    New-Item -ItemType Directory -Path $spacedTemporaryRoot | Out-Null
    $originalTemp = $env:TEMP
    $originalTmp = $env:TMP
    $originalTmpDir = $env:TMPDIR
    try {
        $env:TEMP = $spacedTemporaryRoot
        $env:TMP = $spacedTemporaryRoot
        $env:TMPDIR = $spacedTemporaryRoot
        Assert-Equal $true (Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImagePath $imagePath -ImageSha256 $imageHash -Architecture "AMD64") "new target should import and verify"
        $calls = Get-FakeWslArgumentCalls
        Assert-Equal 3 $calls.Count "local import call count"
        Assert-ArgumentCall -Expected @("--list", "--quiet") -Actual $calls[0] -Message "local initial list"
        Assert-Equal "--install" $calls[1][0] "local import command"
        Assert-Equal "--from-file" $calls[1][1] "local import source flag"
        Assert-Match ([regex]::Escape($spacedTemporaryRoot)) $calls[1][2] "local import staged source should retain spaces as one argument"
        Assert-Match 'openhands-worker-1\.2\.3-amd64\.wsl$' $calls[1][2] "local import staged source leaf"
        Assert-ArgumentCall -Expected @("--install", "--from-file", $calls[1][2], "--name", "openhands-worker", "--no-launch") -Actual $calls[1] -Message "local import argv"
        Assert-ArgumentCall -Expected @("--list", "--quiet") -Actual $calls[2] -Message "local verification list"

        Set-FakeWslScenario -Root $testRoot -Before "docker-desktop" -After "docker-desktop`nopenhands-worker"
        $env:FAKE_WSL_REQUIRE_STAGED_IMAGE = "1"
        $script:DownloadedImageUri = $null
        Assert-Equal $true (Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImageUri "https://example.invalid/openhands-worker-1.2.3-amd64.wsl" -ImageSha256 $imageHash -Architecture "AMD64") "HTTPS image should download, hash, and import"
        Assert-Equal "https://example.invalid/openhands-worker-1.2.3-amd64.wsl" $script:DownloadedImageUri "HTTPS image download URI"
        $calls = Get-FakeWslArgumentCalls
        Assert-Equal 3 $calls.Count "HTTPS import call count"
        Assert-ArgumentCall -Expected @("--list", "--quiet") -Actual $calls[0] -Message "HTTPS initial list"
        Assert-Match ([regex]::Escape($spacedTemporaryRoot)) $calls[1][2] "HTTPS import staged source should retain spaces as one argument"
        Assert-ArgumentCall -Expected @("--install", "--from-file", $calls[1][2], "--name", "openhands-worker", "--no-launch") -Actual $calls[1] -Message "HTTPS import argv"
        Assert-ArgumentCall -Expected @("--list", "--quiet") -Actual $calls[2] -Message "HTTPS verification list"
    }
    finally {
        $env:TEMP = $originalTemp
        $env:TMP = $originalTmp
        $env:TMPDIR = $originalTmpDir
        Remove-Item -LiteralPath $spacedTemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Set-FakeWslScenario -Root $testRoot -ListExit 1
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImagePath $imagePath -ImageSha256 $imageHash -Architecture "AMD64" } "nonzero list should fail"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "nonzero list calls"

    Set-FakeWslScenario -Root $testRoot -InstallExit 1
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImagePath $imagePath -ImageSha256 $imageHash -Architecture "AMD64" } "nonzero import should fail"
    Assert-Match '(?s)^--list --quiet\n--install --from-file .+openhands-worker-1\.2\.3-amd64\.wsl --name openhands-worker --no-launch\n$' (Get-FakeWslCalls) "nonzero import calls"

    Set-FakeWslScenario -Root $testRoot -After "docker-desktop"
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImagePath $imagePath -ImageSha256 $imageHash -Architecture "AMD64" } "missing post-import target should fail"
    Assert-Match '(?s)^--list --quiet\n--install --from-file .+openhands-worker-1\.2\.3-amd64\.wsl --name openhands-worker --no-launch\n--list --quiet\n$' (Get-FakeWslCalls) "missing post-import target calls"

    $temporaryImagesBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "openhands-worker-*" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    function Get-WslImageSha256 {
        param([IO.Stream]$Stream)

        throw "Simulated hash read failure."
    }
    Set-FakeWslScenario -Root $testRoot
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Name "openhands-worker" -ImagePath $imagePath -ImageSha256 $imageHash -Architecture "AMD64" } "hash read failure should fail before import"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "hash read failure should not invoke WSL import"
    $temporaryImagesAfter = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter "openhands-worker-*" -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    Assert-Equal ($temporaryImagesBefore -join "`n") ($temporaryImagesAfter -join "`n") "hash read failure should clean its temporary directory"

    $configPath = Join-Path $testRoot ".wslconfig"
    $original = "[wsl2]`nfirewall=true`nlocalhostForwarding=false`n"
    [System.IO.File]::WriteAllText($configPath, $original, [System.Text.UTF8Encoding]::new($false))

    $result = Set-WslMirroredNetworking -Path $configPath
    Assert-Equal $true $result.Changed "NAT config should change"
    $content = Get-Content $configPath -Raw
    Assert-Match "(?m)^networkingMode=mirrored$" $content
    Assert-Match "(?m)^dnsTunneling=true$" $content
    Assert-Equal $original (Get-Content $result.BackupPath -Raw) "backup"

    $second = Set-WslMirroredNetworking -Path $configPath
    Assert-Equal $false $second.Changed "mirrored config should be idempotent"
    Assert-Equal $null $second.BackupPath "no-op should not back up"

    $mixedEolPath = Join-Path $testRoot "mixed-eol.wslconfig"
    $mixedEol = "[wsl2]`r`nnetworkingMode=mirrored`ndnsTunneling=true`r`nfirewall=true`n"
    [System.IO.File]::WriteAllText($mixedEolPath, $mixedEol, [System.Text.UTF8Encoding]::new($false))
    $mixedEolResult = Set-WslMirroredNetworking -Path $mixedEolPath
    Assert-Equal $false $mixedEolResult.Changed "mixed-EOL mirrored config should be a no-op"
    Assert-Equal $mixedEol (Get-Content $mixedEolPath -Raw) "mixed-EOL config should be unchanged"

    $rollbackPath = Join-Path $testRoot "rollback.wslconfig"
    $rollbackOriginal = "[wsl2]`nnetworkingMode=nat`n"
    [System.IO.File]::WriteAllText($rollbackPath, $rollbackOriginal, [System.Text.UTF8Encoding]::new($false))
    $rollbackChanged = Set-WslMirroredNetworking -Path $rollbackPath
    Restore-WslConfig -Path $rollbackPath -BackupPath $rollbackChanged.BackupPath
    Assert-Equal $rollbackOriginal (Get-Content $rollbackPath -Raw) "rollback should restore an existing config"
    Assert-Equal $rollbackOriginal (Get-Content $rollbackChanged.BackupPath -Raw) "rollback should retain the audit backup"
    Assert-Equal $true (Set-WslMirroredNetworking -Path $rollbackPath).Changed "retry after rollback should change again"

    $missingActivePath = Join-Path $testRoot "missing-active.wslconfig"
    $rollbackBackupPath = Join-Path $testRoot "missing-active.wslconfig.audit.bak"
    [System.IO.File]::WriteAllText($rollbackBackupPath, $rollbackOriginal, [System.Text.UTF8Encoding]::new($false))
    Assert-Throws { Restore-WslConfig -Path $missingActivePath -BackupPath $rollbackBackupPath } "rollback should not non-atomically recreate a missing active config"
    Assert-Equal $false (Test-Path -LiteralPath $missingActivePath) "failed rollback should not leave a partial active config"
    Assert-Equal $rollbackOriginal (Get-Content $rollbackBackupPath -Raw) "failed rollback should retain the audit backup"
    Assert-Equal 0 @((Get-ChildItem -LiteralPath $testRoot -Filter ".missing-active.wslconfig.*.tmp")).Count "failed rollback should clean up its sibling temporary file"

    $newConfigPath = Join-Path $testRoot "new-config.wslconfig"
    $newConfigChanged = Set-WslMirroredNetworking -Path $newConfigPath
    Restore-WslConfig -Path $newConfigPath -BackupPath $newConfigChanged.BackupPath
    Assert-Equal $false (Test-Path -LiteralPath $newConfigPath) "rollback should delete a newly created config"


    $formattedPath = Join-Path $testRoot "formatted.wslconfig"
    [System.IO.File]::WriteAllText($formattedPath, "[wsl2]`n  networkingMode = nat ; retain this`n`tdnsTunneling = false # retain this too`n", [System.Text.UTF8Encoding]::new($false))
    $formattedResult = Set-WslMirroredNetworking -Path $formattedPath
    Assert-Equal $true $formattedResult.Changed "formatted config should change"
    Assert-Match "(?m)^  networkingMode = mirrored ; retain this$" (Get-Content $formattedPath -Raw) "networking format"
    Assert-Match "(?m)^\tdnsTunneling = true # retain this too$" (Get-Content $formattedPath -Raw) "DNS format"
    Assert-Equal 91 ([System.IO.File]::ReadAllBytes($formattedPath)[0]) "write should not add a UTF-8 BOM"

    $missingSectionPath = Join-Path $testRoot "missing-section.wslconfig"
    [System.IO.File]::WriteAllText($missingSectionPath, "[experimental]`nsparseVhd=true`n", [System.Text.UTF8Encoding]::new($false))
    $inserted = Set-WslMirroredNetworking -Path $missingSectionPath
    Assert-Equal $true $inserted.Changed "missing wsl2 section should change"
    Assert-Match "(?ms)^\[wsl2\]\r?\nnetworkingMode=mirrored\r?\ndnsTunneling=true$" (Get-Content $missingSectionPath -Raw)

    $duplicateSectionPath = Join-Path $testRoot "duplicate-section.wslconfig"
    [System.IO.File]::WriteAllText($duplicateSectionPath, "[wsl2]`n[wsl2]`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Throws { Set-WslMirroredNetworking -Path $duplicateSectionPath } "duplicate section"

    $duplicateKeyPath = Join-Path $testRoot "duplicate-key.wslconfig"
    [System.IO.File]::WriteAllText($duplicateKeyPath, "[wsl2]`nnetworkingMode=nat`nnetworkingMode=mirrored`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Throws { Set-WslMirroredNetworking -Path $duplicateKeyPath } "duplicate key"

    $commentPath = Join-Path $testRoot "comment-equals.wslconfig"
    [System.IO.File]::WriteAllText($commentPath, "[wsl2]`n  # note=value`n  # note=value`nnetworkingMode=nat`ndnsTunneling=false`n", [System.Text.UTF8Encoding]::new($false))
    Assert-Equal $true (Set-WslMirroredNetworking -Path $commentPath).Changed "comment lines with equals should not be keys"

    $source = Get-Content $installPath -Raw
    Assert-NotMatch 'IsWindowsVersionAtLeast|File\]::Move\([^\r\n]+,\s*[^\r\n]+,\s*\$true\)|::new\(' $source "Windows PowerShell 5.1 compatibility"
    Assert-NotMatch '\$env:SystemRoot' $source "trusted Windows directory source"
    Assert-Match 'GetFolderPath\s*\(' $source "trusted Windows directory API"
    Assert-NotMatch 'Test-WslDistributionAvailable|Test-WslNamedInstallSupported|Get-WslBootstrapAsset|Invoke-WslBootstrapAssetTransfer|Invoke-WslBaseProvisioning|--list --online|--help|--install --distribution|Ubuntu-26\.04|/root/openhands-bootstrap' $source "installer should not retain dynamic fallback paths"

    Write-Host "PASS: WSL mirrored networking configuration"
}
finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}
