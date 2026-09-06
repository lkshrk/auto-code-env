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

function Assert-Order {
    param([string[]]$Calls, [string]$First, [string]$Second, [string]$Message)

    $firstIndex = [Array]::IndexOf($Calls, $First)
    $secondIndex = [Array]::IndexOf($Calls, $Second)
    if ($firstIndex -lt 0) {
        throw "$Message. '$First' never ran."
    }
    if ($secondIndex -lt 0) {
        throw "$Message. '$Second' never ran."
    }
    if ($firstIndex -ge $secondIndex) {
        throw "$Message. '$First' ran at $firstIndex, '$Second' at $secondIndex."
    }
}

function Assert-NotCalled {
    param([string[]]$Calls, [string]$Call, [string]$Message)

    if ($Calls -contains $Call) {
        throw "$Message. '$Call' must not have run."
    }
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
$updatePath = Join-Path $windows "update.ps1"

$WorkerVersionPattern = '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'
$WorkerDistroPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

foreach ($name in "Get-WorkerInstalledVersion", "Compare-WorkerVersion", "Get-WorkerPasswordBytes",
    "Get-WorkerOverlayArguments", "Get-WslDistributionRegistryKey", "Rename-WslDistribution",
    "Wait-WorkerSystemReady") {
    Invoke-Expression (Import-ScriptFunction -Path $commonPath -Name $name)
}
foreach ($name in "Get-WorkerStagingDistroName", "Get-WorkerUpdateTaskArguments", "Register-WorkerUpdateTask",
    "Test-WorkerStateArchive", "Remove-WorkerStateArchive", "Update-WorkerDistribution") {
    Invoke-Expression (Import-ScriptFunction -Path $updatePath -Name $name)
}

$updateSource = Get-Content -Raw $updatePath
foreach ($required in 'Assert-WorkerElevated', 'Update-WorkerDistribution', 'Compare-WorkerVersion', '--terminate',
    '--unregister', 'DistributionName', 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss|\$WorkerLxssKey',
    '\$Force', '\$Schedule', '-Weekly', '-Hidden', 'state", "export', 'Invoke-WorkerProvision', 'Invoke-WorkerActivation',
    'Wait-WorkerSystemReady', 'CommonProfilePath', 'Get-WorkerGuestProfilePaths') {
    if ($updateSource -notmatch $required) {
        throw "update.ps1 must use $required."
    }
}
if ($updateSource -match '--password-stdin') {
    throw "update.ps1 must not hand-build the password flag; Invoke-WorkerOverlay owns it."
}
Write-Host "PASS: update.ps1 shape"

Assert-Equal "openhands-worker-next" (Get-WorkerStagingDistroName -Distro "openhands-worker") "staging distro name"
Assert-Throws { Get-WorkerStagingDistroName -Distro ("x" * 64) } "is not valid" "an over-long staging name is refused"

Assert-Equal "0.2.1" (Get-WorkerInstalledVersion -Output @("openhands-worker 0.2.1")) "release marker"
Assert-Equal "0.2.1" (Get-WorkerInstalledVersion -Output @("o`0p`0e`0n`0hands-worker 0.2.1")) "UTF-16 padded marker"
Assert-Equal $null (Get-WorkerInstalledVersion -Output @("cat: /etc/openhands/release: No such file or directory")) "a missing marker has no version"
Assert-Equal $null (Get-WorkerInstalledVersion -Output $null) "no output has no version"

Assert-Equal (-1) (Compare-WorkerVersion -Installed $null -Target "0.3.0") "a missing marker is older than everything"
Assert-Equal (-1) (Compare-WorkerVersion -Installed "dev" -Target "0.3.0") "an untagged image is older than everything"
Assert-Equal (-1) (Compare-WorkerVersion -Installed "ci-abcdef123456" -Target "0.3.0") "a CI image is older than everything"
Assert-Equal 0 (Compare-WorkerVersion -Installed "0.3.0" -Target "0.3.0") "equal versions compare equal"
Assert-Equal (-1) (Compare-WorkerVersion -Installed "0.2.9" -Target "0.3.0") "an older version compares older"
Assert-Equal 1 (Compare-WorkerVersion -Installed "0.4.0" -Target "0.3.0") "a newer version compares newer"
Assert-Equal (-1) (Compare-WorkerVersion -Installed "0.3.0-rc.1" -Target "0.3.0") "a prerelease is older than its release"
Assert-Equal 1 (Compare-WorkerVersion -Installed "0.3.0" -Target "0.3.0-rc.1") "a release is newer than its prerelease"
Assert-Throws { Compare-WorkerVersion -Installed "0.3.0" -Target "latest" } "is not a release version" "an unresolved target is refused"
Assert-True ($updateSource -match 'comparison -eq 0 -and -not \$Force') "an equal version is skipped unless -Force is passed"
Assert-True ($updateSource -match 'comparison -gt 0 -and -not \$Force') "a downgrade is refused unless -Force is passed"
Write-Host "PASS: version comparison"

$bytes = Get-WorkerPasswordBytes -Credential (New-Object System.Management.Automation.PSCredential("vault", (ConvertTo-SecureString "s3cr3t" -AsPlainText -Force)))
Assert-Equal "s3cr3t`n" ([Text.Encoding]::UTF8.GetString($bytes)) "the password is written as one line"
Assert-Throws {
    Get-WorkerPasswordBytes -Credential (New-Object System.Management.Automation.PSCredential("vault", (ConvertTo-SecureString "two`nlines" -AsPlainText -Force)))
} "line break" "a multi-line password is refused"
$stateArguments = Get-WorkerOverlayArguments -Distro "openhands-worker-next" -Command @("state", "import")
Assert-True ($stateArguments -notcontains "--password-stdin") "state transfer never claims a password"
Write-Host "PASS: password handling"

$calls = New-Object 'System.Collections.Generic.List[string]'
$failAt = ""
$record = { param($name) $calls.Add($name); if ($failAt -eq $name) { throw "injected failure at $name" } }
$steps = @{
    InstallStaging         = { param($name) & $record "install $name" }
    ProvisionStaging       = { param($name) & $record "provision $name" }
    StopDistribution       = { param($name) & $record "stop $name" }
    ActivateStaging        = { param($name) & $record "activate $name" }
    ResolveDistribution    = { param($name) & $record "resolve $name"; return "HKCU:\Lxss\{guid}" }
    UnregisterDistribution = { param($name) & $record "unregister $name" }
    RenameDistribution     = { param($key, $name) & $record "rename $key $name" }
    RestoreDistribution    = { param($name) & $record "restore $name" }
    RestoreOverlay         = { & $record "restore-overlay" }
    Finalize               = { param($name) & $record "finalize $name" }
}

Update-WorkerDistribution -Distro "openhands-worker" -Staging "openhands-worker-next" @steps
$expected = @(
    "install openhands-worker-next",
    "provision openhands-worker-next",
    "stop openhands-worker",
    "activate openhands-worker-next",
    "resolve openhands-worker-next",
    "stop openhands-worker-next",
    "unregister openhands-worker",
    "rename HKCU:\Lxss\{guid} openhands-worker",
    "finalize openhands-worker")
Assert-Equal ($expected -join " | ") ($calls -join " | ") "the swap runs in the fail-closed order"
Assert-Order -Calls $calls.ToArray() -First "activate openhands-worker-next" -Second "unregister openhands-worker" `
    -Message "the old distribution is unregistered only after the new one is activated and verified"
Assert-Order -Calls $calls.ToArray() -First "resolve openhands-worker-next" -Second "unregister openhands-worker" `
    -Message "the staging registry key is resolved before the old distribution is destroyed"
Assert-Order -Calls $calls.ToArray() -First "stop openhands-worker-next" -Second "rename HKCU:\Lxss\{guid} openhands-worker" `
    -Message "the staging distribution is terminated before it is renamed"
Assert-NotCalled -Calls $calls.ToArray() -Call "restore openhands-worker" -Message "a successful swap does not restore the old distribution"
Assert-NotCalled -Calls $calls.ToArray() -Call "restore-overlay" -Message "a successful swap keeps the refreshed overlay"

foreach ($failure in @("provision openhands-worker-next", "activate openhands-worker-next")) {
    $calls.Clear()
    $failAt = $failure
    Assert-Throws { Update-WorkerDistribution -Distro "openhands-worker" -Staging "openhands-worker-next" @steps } `
        "injected failure" "a failure before the swap aborts the update"
    Assert-True ($calls -contains "unregister openhands-worker-next") "the staging distribution is removed after a failure at '$failure'"
    Assert-NotCalled -Calls $calls.ToArray() -Call "unregister openhands-worker" -Message "the old distribution survives a failure at '$failure'"
    Assert-NotCalled -Calls $calls.ToArray() -Call "rename HKCU:\Lxss\{guid} openhands-worker" -Message "no rename happens after a failure at '$failure'"
    Assert-NotCalled -Calls $calls.ToArray() -Call "finalize openhands-worker" -Message "no finalization happens after a failure at '$failure'"
}

$calls.Clear()
$failAt = "activate openhands-worker-next"
Assert-Throws { Update-WorkerDistribution -Distro "openhands-worker" -Staging "openhands-worker-next" @steps } "injected failure" "activation failure aborts"
Assert-True ($calls -contains "restore openhands-worker") "a distribution stopped for the swap is restarted when activation fails"

$calls.Clear()
$failAt = "install openhands-worker-next"
Assert-Throws { Update-WorkerDistribution -Distro "openhands-worker" -Staging "openhands-worker-next" @steps } "injected failure" "install failure aborts"
Assert-NotCalled -Calls $calls.ToArray() -Call "unregister openhands-worker-next" -Message "a distribution that was never installed is not unregistered"
Assert-NotCalled -Calls $calls.ToArray() -Call "stop openhands-worker" -Message "the old distribution is never touched when the staging install fails"
Assert-True ($calls -contains "restore-overlay") "the previous overlay is put back when the staging install fails"
$failAt = ""
Write-Host "PASS: fail-closed swap"

$registry = @{ "HKCU:\Lxss\{a}" = "openhands-worker"; "HKCU:\Lxss\{b}" = "openhands-worker-next"; "HKCU:\Lxss\{c}" = $null }
$getKeys = { $registry.Keys }
$getName = { param($key) $registry[$key] }
$setName = { param($key, $name) $registry[$key] = $name }

Assert-Equal "HKCU:\Lxss\{b}" (Get-WslDistributionRegistryKey -Name "openhands-worker-next" -GetKeys $getKeys -GetName $getName) "the staging key is found by DistributionName"
Assert-Throws { Get-WslDistributionRegistryKey -Name "absent" -GetKeys $getKeys -GetName $getName } "found 0" "an unknown distribution is refused"
Assert-Throws { Rename-WslDistribution -From "openhands-worker-next" -To "openhands-worker" -GetKeys $getKeys -GetName $getName -SetName $setName } `
    "still registered" "renaming onto a live distribution is refused"

$registry.Remove("HKCU:\Lxss\{a}")
Assert-Equal "HKCU:\Lxss\{b}" (Rename-WslDistribution -From "openhands-worker-next" -To "openhands-worker" -GetKeys $getKeys -GetName $getName -SetName $setName) "rename returns the renamed key"
Assert-Equal "openhands-worker" $registry["HKCU:\Lxss\{b}"] "the staging key now carries the live distribution name"
Assert-Throws { Rename-WslDistribution -From "openhands-worker" -To "bad name" -GetKeys $getKeys -GetName $getName -SetName $setName } "is not valid" "an invalid target name is refused"
Write-Host "PASS: registry rename"

$taskCalls = New-Object 'System.Collections.Generic.List[string]'
$taskExists = $false
$taskSteps = @{
    GetTask        = { param($name) $taskCalls.Add("get $name"); if ($taskExists) { "task" } }
    UnregisterTask = { param($name) $taskCalls.Add("unregister $name") }
    RegisterTask   = { param($name, $arguments, $user) $taskCalls.Add("register $name [$arguments] $user") }
}
Register-WorkerUpdateTask -Name "openhands-worker-update" -ScriptPath "C:\worker\update.ps1" -ConfigPath "C:\ProgramData\openhands-worker\worker.json" -UserId "TOWERR\op" @taskSteps
Assert-Equal 2 $taskCalls.Count "a new task is looked up and registered"
Assert-Equal 'register openhands-worker-update [-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\worker\update.ps1" -Config "C:\ProgramData\openhands-worker\worker.json" -Release latest] TOWERR\op' $taskCalls[1] "the weekly task runs update.ps1 against the same configuration"
$taskCalls.Clear()
$taskExists = $true
Register-WorkerUpdateTask -Name "openhands-worker-update" -ScriptPath "C:\worker\update.ps1" -ConfigPath "C:\ProgramData\openhands-worker\worker.json" -UserId "TOWERR\op" @taskSteps
Assert-Equal "unregister openhands-worker-update" $taskCalls[1] "an existing task is replaced"
Assert-Throws { Get-WorkerUpdateTaskArguments -ScriptPath 'C:\a"b\update.ps1' -ConfigPath "C:\worker.json" } "cannot be used" "a quotable path is refused"
Write-Host "PASS: scheduled update task"

$readyIndex = $updateSource.IndexOf("Wait-WorkerSystemReady -WslPath `$wslPath -Distro `$name", [StringComparison]::Ordinal)
$provisionIndex = $updateSource.IndexOf("Invoke-WorkerProvision -Configuration", [StringComparison]::Ordinal)
Assert-True ($readyIndex -ge 0) "update.ps1 waits for the staging distribution to finish booting"
Assert-True ($readyIndex -lt $provisionIndex) "the readiness wait runs before the first overlay call on the staging distribution"
Write-Host "PASS: readiness wait is wired into staging provisioning"

$root = Join-Path ([IO.Path]::GetTempPath()) ("worker-update-tests-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $fakeWsl = Join-Path $root "fake-wsl"
    $counter = Join-Path $root "boot-count"
    [IO.File]::WriteAllText($fakeWsl, @'
#!/bin/sh
count=0
if [ -f "$FAKE_WSL_BOOT_COUNT" ]; then count=$(cat "$FAKE_WSL_BOOT_COUNT"); fi
count=$((count + 1))
printf '%s' "$count" > "$FAKE_WSL_BOOT_COUNT"
printf '%s\n' "$@" >> "$FAKE_WSL_BOOT_ARGV"
if [ "$count" -lt 2 ]; then printf 'starting\n'; exit 1; fi
printf 'running\n'
'@)
    & chmod +x $fakeWsl
    $env:FAKE_WSL_BOOT_COUNT = $counter
    $env:FAKE_WSL_BOOT_ARGV = Join-Path $root "boot-argv"
    $sleeps = New-Object 'System.Collections.Generic.List[int]'
    Assert-Equal "running" (Wait-WorkerSystemReady -WslPath $fakeWsl -Distro "openhands-worker-next" -Wait { param($seconds) $sleeps.Add($seconds) }) "a distribution that reports starting then running is waited out"
    Assert-Equal 1 $sleeps.Count "the poll sleeps once between the two probes"
    $bootArgv = [IO.File]::ReadAllText($env:FAKE_WSL_BOOT_ARGV)
    Assert-True ($bootArgv -match '(?m)^is-system-running$') "the probe asks systemd whether the system finished booting"
    Assert-True ($bootArgv -match '(?m)^/usr/bin/systemctl$') "the probe runs systemctl by absolute path"
    Assert-True ($bootArgv -match '(?m)^openhands-worker-next$') "the probe targets the staging distribution"

    Assert-Equal "degraded" (Wait-WorkerSystemReady -WslPath $fakeWsl -Distro "openhands-worker-next" -Probe { param($path, $name) "degraded" } -Wait { param($seconds) }) "a degraded system counts as booted"
    $probes = 0
    Assert-Throws {
        Wait-WorkerSystemReady -WslPath $fakeWsl -Distro "openhands-worker-next" -TimeoutSeconds 120 -IntervalSeconds 2 `
            -Probe { param($path, $name) $script:probes++; "starting" } -Wait { param($seconds) }
    } "did not finish booting within 120 seconds" "a distribution that never boots is refused"
    Assert-Equal 61 $probes "the poll runs for the whole 120 second budget at a 2 second interval"
    Assert-Throws { Wait-WorkerSystemReady -WslPath $fakeWsl -Distro "bad name; rm" } "is not valid" "a distro name with shell characters is refused"
    Write-Host "PASS: staging readiness wait"

    $archive = Join-Path $root "state-20260905120000.tar.gz"
    Assert-Throws { Test-WorkerStateArchive -Path $archive -ListArchive { param($path) @("home/agent/.openhands") } } "was not written" "a missing state archive is refused"
    [IO.File]::WriteAllBytes($archive, [byte[]]@())
    Assert-Throws { Test-WorkerStateArchive -Path $archive -ListArchive { param($path) @("home/agent/.openhands") } } "is empty" "an empty state archive is refused"
    [IO.File]::WriteAllBytes($archive, [byte[]]@(31, 139, 8, 0))
    Assert-Throws { Test-WorkerStateArchive -Path $archive -ListArchive { param($path) @() } } "no entries" "an unreadable state archive is refused"
    Assert-Equal 2 (Test-WorkerStateArchive -Path $archive -ListArchive { param($path) @("home/agent/.openhands", "home/agent/.claude") }) "a readable state archive lists its entries"

    $older = Join-Path $root "state-20260901120000.tar.gz"
    [IO.File]::WriteAllBytes($older, [byte[]]@(31, 139))
    Remove-WorkerStateArchive -Directory $root -Keep $archive
    Assert-True (Test-Path -LiteralPath $archive) "the current state archive is kept"
    Assert-True (-not (Test-Path -LiteralPath $older)) "the previous state archive is removed"
    Write-Host "PASS: state archive handling"
}
finally {
    Remove-Item -Path Env:FAKE_WSL_BOOT_COUNT, Env:FAKE_WSL_BOOT_ARGV -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PASS: update.ps1"
