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

if [ "$1" = "--help" ]; then
    if [ "$FAKE_WSL_HELP_NUL" = "1" ]; then
        printf '%s' "$FAKE_WSL_HELP" | awk '{ for (i = 1; i <= length($0); i++) { printf "%s%c", substr($0, i, 1), 0 } }'
        printf '\n'
    else
        printf '%s\n' "$FAKE_WSL_HELP"
    fi
    exit "${FAKE_WSL_HELP_EXIT:-0}"
fi

if [ "$1" = "--install" ]; then
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

if [ "$1" = "--distribution" ] && [ "$3" = "--user" ] && [ "$4" = "root" ] && [ "$5" = "--exec" ] && [ "$6" = "sh" ]; then
    exit "${FAKE_WSL_STAGE4B_TRANSFER_EXIT:-0}"
fi

if [ "$1" = "--distribution" ] && [ "$3" = "--user" ] && [ "$4" = "root" ] && [ "$5" = "--exec" ] && [ "$6" = "/bin/bash" ]; then
    exit "${FAKE_WSL_STAGE4B_PROVISION_EXIT:-0}"
fi

if [ "$1" = "--distribution" ] && [ "$3" = "--exec" ] && [ "$4" = "sh" ]; then
    exit "${FAKE_WSL_STAGE4B_VERIFY_EXIT:-0}"
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
        [string]$Help = "--name <Name>",
        [int]$HelpExit = 0,
        [int]$ListExit = 0,
        [int]$InstallExit = 0,
        [bool]$NulHelp = $false,
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
    $env:FAKE_WSL_HELP = $Help
    $env:FAKE_WSL_HELP_EXIT = "$HelpExit"
    $env:FAKE_WSL_LIST_EXIT = "$ListExit"
    $env:FAKE_WSL_INSTALL_EXIT = "$InstallExit"
    $env:FAKE_WSL_HELP_NUL = if ($NulHelp) { "1" } else { "0" }
    $env:FAKE_WSL_EMPTY_INITIAL_LIST = if ($EmptyInitialList) { "1" } else { "0" }
    $env:FAKE_WSL_ID = $Id
    $env:FAKE_WSL_RELEASE = $Release
    $env:FAKE_WSL_ID_EXIT = "$IdExit"
    $env:FAKE_WSL_RELEASE_EXIT = "$ReleaseExit"
    $env:FAKE_WSL_TERMINATE_EXIT = "$TerminateExit"
    $env:FAKE_WSL_ID_NUL = if ($NulId) { "1" } else { "0" }
    $env:FAKE_WSL_RELEASE_NUL = if ($NulRelease) { "1" } else { "0" }
    $env:FAKE_WSL_STAGE4B_TRANSFER_EXIT = "0"
    $env:FAKE_WSL_STAGE4B_PROVISION_EXIT = "0"
    $env:FAKE_WSL_STAGE4B_VERIFY_EXIT = "0"
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
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-WslDistributionAvailable")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-WslNamedInstallSupported")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-WslDistributionRegistered")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Install-WslDistribution")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslExecutablePath")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-WslVersionSupported")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Restore-WslConfig")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-UbuntuRelease")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Assert-WslDistributionIdentity")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslBootstrapAsset")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslShellProgramWrapper")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "ConvertTo-WslShellProgramBase64")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslBaseProvisioningTransferCommand")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslBaseProvisioningIsolationCommand")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Get-WslBaseProvisioningVerificationCommand")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Invoke-WslBaseProvisioning")))

    Assert-Equal "C:\Windows\System32\wsl.exe" (Get-WslExecutablePath -WindowsDirectory "C:\Windows" -Is64BitProcess $true -Is64BitOperatingSystem $true) "64-bit process WSL path"
    Assert-Equal "C:\Windows\Sysnative\wsl.exe" (Get-WslExecutablePath -WindowsDirectory "C:\Windows" -Is64BitProcess $false -Is64BitOperatingSystem $true) "32-bit process WSL path"
    Assert-Equal "C:\Windows\System32\wsl.exe" (Get-WslExecutablePath -WindowsDirectory "C:\Windows" -Is64BitProcess $false -Is64BitOperatingSystem $false) "32-bit OS WSL path"

    Assert-Equal $true (Test-WslVersionSupported -Output @("WSL version: 2.7.0", "Kernel version: 6.6")) "WSL 2.7.0 should be supported"
    Assert-Equal $false (Test-WslVersionSupported -Output @("WSL version: 2.6.9")) "WSL 2.6.9 should be rejected"
    Assert-Equal $false (Test-WslVersionSupported -Output @("WSL version: unknown")) "malformed WSL version should be rejected"
    Assert-Equal $true (Test-WslVersionSupported -Output @("WSL-Version: 2.7.10.0", "Kernel-Version: 6.6")) "localized WSL 2.7.10.0 should be supported"
    $nulSeparatedVersion = [string]::Join([char]0, [char[]]"WSL version: 2.7.0")
    Assert-Equal $true (Test-WslVersionSupported -Output @($nulSeparatedVersion)) "NUL-separated WSL 2.7.0 should be supported"

    $onlineOutput = @(
        "The following is a list of valid distributions that can be installed.",
        "Install using 'wsl.exe --install <Distro>'.",
        "",
        "NAME                            FRIENDLY NAME",
        "Ubuntu-26.04                    Ubuntu 26.04 LTS"
    )
    Assert-Equal $true (Test-WslDistributionAvailable -Output $onlineOutput -Distribution "Ubuntu-26.04") "exact online distribution should be available"
    Assert-Equal $false (Test-WslDistributionAvailable -Output @("Ubuntu-26.04-extra             Wrong") -Distribution "Ubuntu-26.04") "near-match distribution should be unavailable"
    $nulSeparatedLine = [string]::Join([char]0, [char[]]"Ubuntu-26.04                    Ubuntu 26.04 LTS")
    Assert-Equal $true (Test-WslDistributionAvailable -Output @($nulSeparatedLine) -Distribution "Ubuntu-26.04") "NUL-separated online distribution should be available"

    $installHelp = @(
        "Usage: wsl.exe [Argument] [Options...] [CommandLine]",
        "    --install [Distro] [Options]",
        "        --distribution, -d <Distro>",
        "        --name <Name>",
        "        --no-launch"
    )
    Assert-Equal $true (Test-WslNamedInstallSupported -Output $installHelp) "literal named-install help should be supported"
    Assert-Equal $false (Test-WslNamedInstallSupported -Output @("        --name-suffix <Name>")) "near-match named-install help should be rejected"
    $nulSeparatedHelp = [string]::Join([char]0, [char[]]"        --name <Name>")
    Assert-Equal $true (Test-WslNamedInstallSupported -Output @($nulSeparatedHelp)) "NUL-separated named-install help should be supported"

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
    Set-FakeWslScenario -Root $testRoot -Before "openhands-worker" -Help "--name-suffix <Name>"
    Assert-Equal $false (Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker") "existing target should be a no-op before help gating"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "existing target should only be listed"

    Set-FakeWslScenario -Root $testRoot -Before "docker-desktop" -After "docker-desktop`nopenhands-worker"
    Assert-Equal $true (Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker") "new target should install and verify"
    Assert-Equal "--list --quiet`n--help`n--install --distribution Ubuntu-26.04 --name openhands-worker --no-launch`n--list --quiet`n" (Get-FakeWslCalls) "named install call order"

    Set-FakeWslScenario -Root $testRoot -After "openhands-worker" -EmptyInitialList $true
    Assert-Equal $true (Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker") "clean host should install and verify"
    Assert-Equal "--list --quiet`n--help`n--install --distribution Ubuntu-26.04 --name openhands-worker --no-launch`n--list --quiet`n" (Get-FakeWslCalls) "clean host named install calls"

    Set-FakeWslScenario -Root $testRoot -Help "--name-suffix <Name>"
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker" } "missing named-install help should fail"
    Assert-Equal "--list --quiet`n--help`n" (Get-FakeWslCalls) "missing named-install help calls"

    Set-FakeWslScenario -Root $testRoot -After "openhands-worker" -HelpExit 1 -NulHelp $true
    Assert-Equal $true (Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker") "valid NUL-separated help should override its nonzero exit"
    Assert-Equal "--list --quiet`n--help`n--install --distribution Ubuntu-26.04 --name openhands-worker --no-launch`n--list --quiet`n" (Get-FakeWslCalls) "nonzero informational help calls"

    Set-FakeWslScenario -Root $testRoot -Help "--name-suffix <Name>" -HelpExit 1
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker" } "nonzero help without named install should fail"
    Assert-Equal "--list --quiet`n--help`n" (Get-FakeWslCalls) "nonzero unsupported help calls"

    Set-FakeWslScenario -Root $testRoot -ListExit 1
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker" } "nonzero list should fail"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "nonzero list calls"

    Set-FakeWslScenario -Root $testRoot -InstallExit 1
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker" } "nonzero install should fail"
    Assert-Equal "--list --quiet`n--help`n--install --distribution Ubuntu-26.04 --name openhands-worker --no-launch`n" (Get-FakeWslCalls) "nonzero install calls"

    Set-FakeWslScenario -Root $testRoot -After "docker-desktop"
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker" } "missing post-install target should fail"
    Assert-Equal "--list --quiet`n--help`n--install --distribution Ubuntu-26.04 --name openhands-worker --no-launch`n--list --quiet`n" (Get-FakeWslCalls) "missing post-install target calls"

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

    $assetDirectory = Join-Path $testRoot "assets"
    New-Item -ItemType Directory -Path $assetDirectory | Out-Null
    $provisionAsset = Join-Path $assetDirectory "provision.sh"
    $configAsset = Join-Path $assetDirectory "wsl.conf"
    [System.IO.File]::WriteAllBytes($provisionAsset, [byte[]](35, 33, 47, 98, 105, 110, 47, 115, 104, 10))
    [System.IO.File]::WriteAllBytes($configAsset, [byte[]](91, 117, 115, 101, 114, 93, 10))
    $asset = Get-WslBootstrapAsset -Path $provisionAsset
    Assert-Equal "IyEvYmluL3NoCg==" $asset.Base64 "asset bytes should use base64 without text conversion"
    Assert-Equal "a8076d3d28d21e02012b20eaf7dbf75409a6277134439025f282e368e3305abf" $asset.Sha256 "asset hash should cover exact bytes"
    $linkedAsset = Join-Path $assetDirectory "linked.conf"
    New-Item -ItemType SymbolicLink -Path $linkedAsset -Target $configAsset | Out-Null
    Assert-Throws { Get-WslBootstrapAsset -Path $linkedAsset } "reparse-point bootstrap source should fail"

    Set-FakeWslScenario -Root $testRoot
    Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath $provisionAsset -ConfigPath $configAsset
    $stage4bCalls = Get-FakeWslCalls
    Assert-Match '(?s)^--distribution openhands-worker --user root --exec sh -ec .*\n--distribution openhands-worker --user root --exec /bin/bash /root/openhands-bootstrap/provision.sh\n--terminate openhands-worker\n--distribution openhands-worker --exec sh -ec .*\n--terminate openhands-worker\n$' $stage4bCalls "Stage 4B should transfer, provision, restart, verify, and stop only the target"
    Assert-Match 'IyEvYmluL3NoCg== a8076d3d28d21e02012b20eaf7dbf75409a6277134439025f282e368e3305abf W3VzZXJdCg== 37411c06650b34746ff1b60a9bb4148608d868972b658eb56bbacea8f504f7b2' $stage4bCalls "Stage 4B should pass exact asset bytes and hashes"
    $stage4bArguments = Get-FakeWslArgumentCalls
    Assert-Equal 5 $stage4bArguments.Count "Stage 4B should make exactly five WSL calls"
    $transferProgram = Get-WslBaseProvisioningTransferCommand
    $transferProgramBase64 = ConvertTo-WslShellProgramBase64 -Program $transferProgram
    $expectedTransferArguments = @("--distribution", "openhands-worker", "--user", "root", "--exec", "sh", "-ec", (Get-WslShellProgramWrapper), "sh", $transferProgramBase64, "IyEvYmluL3NoCg==", "a8076d3d28d21e02012b20eaf7dbf75409a6277134439025f282e368e3305abf", "W3VzZXJdCg==", "37411c06650b34746ff1b60a9bb4148608d868972b658eb56bbacea8f504f7b2") -join [char]0
    Assert-Equal $expectedTransferArguments ($stage4bArguments[0] -join [char]0) "transfer argv boundaries and positions"
    Assert-NotMatch "`n" $stage4bArguments[0][7] "native transfer wrapper must be single-line"
    Assert-NotMatch "'" $stage4bArguments[0][7] "native transfer wrapper must not contain single quotes"
    Assert-NotMatch ([string][char]34) $stage4bArguments[0][7] "native transfer wrapper must not contain double quotes"
    Assert-Equal $transferProgram ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stage4bArguments[0][9]))) "transfer program base64 must preserve exact UTF-8 bytes"
    $verificationProgram = Get-WslBaseProvisioningVerificationCommand
    $verificationProgramBase64 = ConvertTo-WslShellProgramBase64 -Program $verificationProgram
    $expectedVerificationArguments = @("--distribution", "openhands-worker", "--exec", "sh", "-ec", (Get-WslShellProgramWrapper), "sh", $verificationProgramBase64) -join [char]0
    Assert-Equal $expectedVerificationArguments ($stage4bArguments[3] -join [char]0) "verification argv boundaries and fixed shell body"
    Assert-NotMatch "`n" $stage4bArguments[3][5] "native verification wrapper must be single-line"
    Assert-NotMatch "'" $stage4bArguments[3][5] "native verification wrapper must not contain single quotes"
    Assert-NotMatch ([string][char]34) $stage4bArguments[3][5] "native verification wrapper must not contain double quotes"
    Assert-Equal $verificationProgram ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stage4bArguments[3][7]))) "verification program base64 must preserve exact UTF-8 bytes"
    Assert-Match '\[ -z "\$\{WSL_INTEROP:-\}" \]' $verificationProgram "Stage 4B should verify WSL_INTEROP is absent"
    Assert-Match '\[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop \]' $verificationProgram "Stage 4B should verify WSLInterop binfmt is absent"
    $verificationRoot = Join-Path $testRoot ("verification-" + [Guid]::NewGuid().ToString("N"))
    $safeAgentPaths = @(".openhands", ".claude", ".codex", "workspaces") | ForEach-Object { Join-Path $verificationRoot $_ }
    New-Item -ItemType Directory -Path $verificationRoot | Out-Null
    foreach ($path in $safeAgentPaths) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
    & chmod 700 @safeAgentPaths
    Assert-Equal 0 $LASTEXITCODE "verification test setup should set private directory modes"
    $currentUser = ((& id -un) -join "").Trim()
    $currentGroup = ((& id -gn) -join "").Trim()
    $pidOne = [System.IO.File]::ReadAllText("/proc/1/comm").Trim()
    $safeVerificationProgram = $verificationProgram.Replace('[ "$(id -un)" = agent ]', ('[ "$(id -un)" = ' + $currentUser + ' ]'))
    $safeVerificationProgram = $safeVerificationProgram.Replace('[ "$(cat /proc/1/comm)" = systemd ]', ('[ "$(cat /proc/1/comm)" = ' + $pidOne + ' ]'))
    $safeVerificationProgram = $safeVerificationProgram.Replace('/mnt/c', (Join-Path $verificationRoot "mnt-c"))
    $safeVerificationProgram = $safeVerificationProgram.Replace('/proc/sys/fs/binfmt_misc/WSLInterop', (Join-Path $verificationRoot "WSLInterop"))
    for ($index = 0; $index -lt $safeAgentPaths.Count; $index++) {
        $safeVerificationProgram = $safeVerificationProgram.Replace(@('/home/agent/.openhands', '/home/agent/.claude', '/home/agent/.codex', '/home/agent/workspaces')[$index], $safeAgentPaths[$index])
    }
    $safeVerificationProgram = $safeVerificationProgram.Replace('agent:agent 700', "${currentUser}:${currentGroup} 700")
    $previousInterop = $env:WSL_INTEROP
    try {
        $env:WSL_INTEROP = ""
        & sh -ec (Get-WslShellProgramWrapper) sh (ConvertTo-WslShellProgramBase64 -Program $safeVerificationProgram)
        Assert-Equal 0 $LASTEXITCODE "combined verification program should execute with mapped target facts"
        $verificationLines = @($verificationProgram -split "`n")
        Assert-Equal 10 $verificationLines.Count "combined verification program line count"
        Assert-Equal '[ ! -e /mnt/c ]' $verificationLines[3] "mount check line boundary"
        Assert-Equal 'set -e' $verificationLines[4] "isolation fragment start line boundary"
        Assert-Equal '[ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ]' $verificationLines[6] "isolation fragment end line boundary"
        Assert-Equal 'for path in /home/agent/.openhands /home/agent/.claude /home/agent/.codex /home/agent/workspaces; do' $verificationLines[7] "directory loop line boundary"

        $isolationWrapper = Get-WslShellProgramWrapper
        $isolationProgram = ConvertTo-WslShellProgramBase64 -Program (Get-WslBaseProvisioningIsolationCommand)
        & sh -ec $isolationWrapper sh $isolationProgram
        Assert-Equal 0 $LASTEXITCODE "verification wrapper should accept an empty WSL_INTEROP and absent binfmt"
        $env:WSL_INTEROP = "unexpected"
        & sh -ec $isolationWrapper sh $isolationProgram
        Assert-Equal 1 $LASTEXITCODE "verification wrapper should reject WSL_INTEROP"
    }
    finally {
        $env:WSL_INTEROP = $previousInterop
        Remove-Item -LiteralPath $verificationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $wrapperTempRoot = Join-Path $testRoot ("wrapper-temp-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $wrapperTempRoot | Out-Null
    $previousTmpDir = $env:TMPDIR
    try {
        $env:TMPDIR = $wrapperTempRoot
        & sh -ec (Get-WslShellProgramWrapper) sh "not-base64"
        Assert-Equal 1 $LASTEXITCODE "wrapper should preserve decode failure status"
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $wrapperTempRoot -Force).Count "wrapper should remove its temporary program after decode failure"

        $failingProgram = ConvertTo-WslShellProgramBase64 -Program "exit 23"
        & sh -ec (Get-WslShellProgramWrapper) sh $failingProgram
        Assert-Equal 23 $LASTEXITCODE "wrapper should preserve inner program failure status"
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $wrapperTempRoot -Force).Count "wrapper should remove its temporary program after inner program failure"
    }
    finally {
        $env:TMPDIR = $previousTmpDir
        Remove-Item -LiteralPath $wrapperTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Set-FakeWslScenario -Root $testRoot
    $env:FAKE_WSL_STAGE4B_TRANSFER_EXIT = "1"
    $env:FAKE_WSL_TERMINATE_EXIT = "1"
    Assert-ThrowsMessage -Action { Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath $provisionAsset -ConfigPath $configAsset } -Patterns @("transfer", "terminate") -Message "transfer and cleanup failures should both be reported"
    Assert-Match '(?s)^--distribution openhands-worker --user root --exec sh -ec .*\n--terminate openhands-worker\n$' (Get-FakeWslCalls) "transfer failure should terminate only the target"

    Set-FakeWslScenario -Root $testRoot
    $env:FAKE_WSL_STAGE4B_PROVISION_EXIT = "1"
    Assert-Throws { Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath $provisionAsset -ConfigPath $configAsset } "provision failure should fail"
    Assert-Match '(?s)^--distribution openhands-worker --user root --exec sh -ec .*\n--distribution openhands-worker --user root --exec /bin/bash /root/openhands-bootstrap/provision.sh\n--terminate openhands-worker\n$' (Get-FakeWslCalls) "provision failure should terminate only the target"

    Set-FakeWslScenario -Root $testRoot
    $env:FAKE_WSL_STAGE4B_VERIFY_EXIT = "1"
    Assert-Throws { Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath $provisionAsset -ConfigPath $configAsset } "verification failure should fail"
    Assert-Match '(?s)--distribution openhands-worker --exec sh -ec .*\n--terminate openhands-worker\n$' (Get-FakeWslCalls) "verification failure should leave only the target stopped"

    Set-FakeWslScenario -Root $testRoot
    $env:FAKE_WSL_STAGE4B_VERIFY_EXIT = "1"
    $env:FAKE_WSL_TERMINATE_EXIT = "1"
    Assert-ThrowsMessage -Action { Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath $provisionAsset -ConfigPath $configAsset } -Patterns @("restart", "terminate") -Message "restart and cleanup failures should both be reported"

    Assert-Throws { Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath (Join-Path $assetDirectory "missing.sh") -ConfigPath $configAsset } "missing bootstrap source should fail before WSL starts"

    $bootstrapPath = Join-Path $testRoot ("bootstrap-" + [Guid]::NewGuid().ToString("N"))
    Assert-NotMatch '^/root(?:/|$)' $bootstrapPath "transfer shell test path must stay inside the test root"
    Assert-Match ('^' + [regex]::Escape($testRoot) + [regex]::Escape([IO.Path]::DirectorySeparatorChar)) $bootstrapPath "transfer shell test path must be under the test root"
    try {
        $transfer = Get-WslBaseProvisioningTransferCommand
        $productionBootstrap = "bootstrap=/root/openhands-bootstrap"
        Assert-Equal 1 ([regex]::Matches($transfer, [regex]::Escape($productionBootstrap))).Count "production bootstrap assignment should be replaced exactly once"
        $transfer = $transfer.Replace($productionBootstrap, "bootstrap='$bootstrapPath'")
        Assert-NotMatch '/root/openhands-bootstrap' $transfer "execution test must not use the production bootstrap path"
        $transferProgramBase64 = ConvertTo-WslShellProgramBase64 -Program $transfer
        $wrapper = Get-WslShellProgramWrapper
        & sh -ec $wrapper sh $transferProgramBase64 "IyEvYmluL3NoCg==" "a8076d3d28d21e02012b20eaf7dbf75409a6277134439025f282e368e3305abf" "W3VzZXJdCg==" "37411c06650b34746ff1b60a9bb4148608d868972b658eb56bbacea8f504f7b2"
        Assert-Equal 0 $LASTEXITCODE "first transfer shell run should succeed"
        Assert-Equal "IyEvYmluL3NoCg==" ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$bootstrapPath/provision.sh"))) "transfer shell should write exact provision bytes"
        Assert-Equal "W3VzZXJdCg==" ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$bootstrapPath/wsl.conf"))) "transfer shell should write exact config bytes"
        Assert-Equal "root:root 700" ((& stat -c '%U:%G %a' "$bootstrapPath/provision.sh").Trim()) "transfer shell provision ownership and mode"
        Assert-Equal "root:root 600" ((& stat -c '%U:%G %a' "$bootstrapPath/wsl.conf").Trim()) "transfer shell config ownership and mode"
        & sh -ec $wrapper sh $transferProgramBase64 "IyEvYmluL3NoCg==" "a8076d3d28d21e02012b20eaf7dbf75409a6277134439025f282e368e3305abf" "W3VzZXJdCg==" "37411c06650b34746ff1b60a9bb4148608d868972b658eb56bbacea8f504f7b2"
        Assert-Equal 0 $LASTEXITCODE "transfer shell rerun should accept canonical modes"
        & sh -ec $wrapper sh $transferProgramBase64 "IyEvYmluL3NoCg==" ("0" * 64) "W3VzZXJdCg==" "37411c06650b34746ff1b60a9bb4148608d868972b658eb56bbacea8f504f7b2"
        Assert-Equal 1 $LASTEXITCODE "transfer shell should reject a mismatched SHA-256"
        Assert-Equal "IyEvYmluL3NoCg==" ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$bootstrapPath/provision.sh"))) "failed hash verification should preserve the prior asset"
        & sh -ec $wrapper sh "not-base64" "IyEvYmluL3NoCg==" "a8076d3d28d21e02012b20eaf7dbf75409a6277134439025f282e368e3305abf" "W3VzZXJdCg==" "37411c06650b34746ff1b60a9bb4148608d868972b658eb56bbacea8f504f7b2"
        Assert-Equal 1 $LASTEXITCODE "wrapper should reject a corrupted program payload"
    }
    finally {
        if (Test-Path -LiteralPath $bootstrapPath) {
            Remove-Item -LiteralPath $bootstrapPath -Recurse -Force
        }
    }

    Set-FakeWslScenario -Root $testRoot
    Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath $provisionAsset -ConfigPath $configAsset
    Invoke-WslBaseProvisioning -WslPath $fakeWslPath -Name "openhands-worker" -ProvisionPath $provisionAsset -ConfigPath $configAsset
    Assert-Equal 4 ([regex]::Matches((Get-FakeWslCalls), '(?m)^--terminate openhands-worker$')).Count "reruns should stop only the target after each restart and verification"

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

    Write-Host "PASS: WSL mirrored networking configuration"
}
finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}
