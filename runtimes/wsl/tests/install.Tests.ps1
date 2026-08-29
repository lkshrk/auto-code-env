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

if [ "$1" = "--list" ] && [ "$2" = "--quiet" ]; then
    count=0
    if [ -f "$FAKE_WSL_LIST_COUNT" ]; then
        count=$(cat "$FAKE_WSL_LIST_COUNT")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_WSL_LIST_COUNT"
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$FAKE_WSL_LIST_BEFORE"
    else
        printf '%s\n' "$FAKE_WSL_LIST_AFTER"
    fi
    exit "${FAKE_WSL_LIST_EXIT:-0}"
fi

if [ "$1" = "--help" ]; then
    printf '%s\n' "$FAKE_WSL_HELP"
    exit "${FAKE_WSL_HELP_EXIT:-0}"
fi

if [ "$1" = "--install" ]; then
    exit "${FAKE_WSL_INSTALL_EXIT:-0}"
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
        [int]$InstallExit = 0
    )

    $env:FAKE_WSL_LOG = Join-Path $Root "fake-wsl.log"
    $env:FAKE_WSL_LIST_COUNT = Join-Path $Root "fake-wsl.list-count"
    [System.IO.File]::WriteAllText($env:FAKE_WSL_LOG, "", [System.Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $env:FAKE_WSL_LIST_COUNT -Force -ErrorAction SilentlyContinue
    $env:FAKE_WSL_LIST_BEFORE = $Before
    $env:FAKE_WSL_LIST_AFTER = $After
    $env:FAKE_WSL_HELP = $Help
    $env:FAKE_WSL_HELP_EXIT = "$HelpExit"
    $env:FAKE_WSL_LIST_EXIT = "$ListExit"
    $env:FAKE_WSL_INSTALL_EXIT = "$InstallExit"
}

function Get-FakeWslCalls {
    return [System.IO.File]::ReadAllText($env:FAKE_WSL_LOG)
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

    $fakeWslPath = New-FakeWslExecutable -Root $testRoot
    Set-FakeWslScenario -Root $testRoot -Before "openhands-worker" -Help "--name-suffix <Name>"
    Assert-Equal $false (Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker") "existing target should be a no-op before help gating"
    Assert-Equal "--list --quiet`n" (Get-FakeWslCalls) "existing target should only be listed"

    Set-FakeWslScenario -Root $testRoot -Before "docker-desktop" -After "docker-desktop`nopenhands-worker"
    Assert-Equal $true (Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker") "new target should install and verify"
    Assert-Equal "--list --quiet`n--help`n--install --distribution Ubuntu-26.04 --name openhands-worker --no-launch`n--list --quiet`n" (Get-FakeWslCalls) "named install call order"

    Set-FakeWslScenario -Root $testRoot -Help "--name-suffix <Name>"
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker" } "missing named-install help should fail"
    Assert-Equal "--list --quiet`n--help`n" (Get-FakeWslCalls) "missing named-install help calls"

    Set-FakeWslScenario -Root $testRoot -HelpExit 1
    Assert-Throws { Install-WslDistribution -WslPath $fakeWslPath -Distribution "Ubuntu-26.04" -Name "openhands-worker" } "nonzero help should fail"
    Assert-Equal "--list --quiet`n--help`n" (Get-FakeWslCalls) "nonzero help calls"

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
