$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    if ($Expected -ne $Actual) {
        throw "$Message. Expected '$Expected', got '$Actual'."
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
        throw "$Name is missing."
    }

    return $function.Extent.Text
}

$scriptPath = Join-Path $PSScriptRoot "..\windows\keepalive.ps1"
$source = Get-Content -Raw $scriptPath
foreach ($required in '-ExecutionTimeLimit \(\[TimeSpan\]::Zero\)', '-MultipleInstances IgnoreNew', '-Hidden', '-DontStopIfGoingOnBatteries', '-RunLevel Limited', '-AtLogOn', 'Start-ScheduledTask', 'Stop-ScheduledTask', 'wscript.exe') {
    if ($source -notmatch $required) {
        throw "keepalive.ps1 must use $required."
    }
}
if ($source -match 'RunLevel Highest') {
    throw "keepalive must not run elevated."
}
foreach ($name in "Get-KeepaliveLauncherContent", "Get-KeepaliveArguments", "Register-WorkerKeepalive") {
    Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name $name)
}

$launcher = Get-KeepaliveLauncherContent -Distro "openhands-worker" -WslPath "C:\Windows\System32\wsl.exe"
Assert-Equal 'CreateObject("WScript.Shell").Run """C:\Windows\System32\wsl.exe"" -d openhands-worker --user root --exec /bin/sleep infinity", 0, True' $launcher "launcher starts wsl with window style 0 and waits, so no console ever exists"
Assert-Throws { Get-KeepaliveLauncherContent -Distro "bad name; rm" -WslPath "C:\Windows\System32\wsl.exe" } "not valid" "distro names with shell characters are refused"
Assert-Throws { Get-KeepaliveLauncherContent -Distro "openhands-worker" -WslPath 'C:\evil" & calc\wsl.exe' } "cannot be launched safely" "wsl path with shell characters is refused"
Assert-Equal '//B //Nologo "C:\ProgramData\openhands-worker\keepalive-openhands-worker.vbs"' (Get-KeepaliveArguments -LauncherPath "C:\ProgramData\openhands-worker\keepalive-openhands-worker.vbs") "wscript runs the launcher in batch mode"
Write-Host "PASS: keepalive arguments"

$calls = New-Object 'System.Collections.Generic.List[string]'
$exists = $false
$common = @{
    WriteLauncher  = { param($path, $content) $calls.Add("write $path") }
    GetTask        = { param($name) $calls.Add("get $name"); if ($exists) { "task" } }
    StopTask       = { param($name) $calls.Add("stop $name") }
    UnregisterTask = { param($name) $calls.Add("unregister $name") }
    RegisterTask   = { param($name, $exe, $arguments, $user) $calls.Add("register $name $exe [$arguments] $user") }
    StartTask      = { param($name) $calls.Add("start $name") }
}

Register-WorkerKeepalive -Name "openhands-worker-keepalive" -Distro "openhands-worker" -WslPath "C:\Windows\System32\wsl.exe" -HostPath "C:\Windows\System32\wscript.exe" -LauncherPath "C:\ProgramData\openhands-worker\keepalive-openhands-worker.vbs" -UserId "TOWERR\op" @common
Assert-Equal "write C:\ProgramData\openhands-worker\keepalive-openhands-worker.vbs" $calls[0] "launcher written before the task is touched"
Assert-Equal "get openhands-worker-keepalive" $calls[1] "existing task lookup"
Assert-Equal 'register openhands-worker-keepalive C:\Windows\System32\wscript.exe [//B //Nologo "C:\ProgramData\openhands-worker\keepalive-openhands-worker.vbs"] TOWERR\op' $calls[2] "task registered with wscript and the launcher"
Assert-Equal "start openhands-worker-keepalive" $calls[3] "task started immediately"
Assert-Equal 4 $calls.Count "no unregister when task is new"

$calls.Clear()
$exists = $true
Register-WorkerKeepalive -Name "openhands-worker-keepalive" -Distro "openhands-worker" -WslPath "C:\Windows\System32\wsl.exe" -HostPath "C:\Windows\System32\wscript.exe" -LauncherPath "C:\ProgramData\openhands-worker\keepalive-openhands-worker.vbs" -UserId "TOWERR\op" @common
Assert-Equal "stop openhands-worker-keepalive" $calls[2] "existing task is stopped before replacement so the old instance cannot block the new start"
Assert-Equal "unregister openhands-worker-keepalive" $calls[3] "existing task is replaced"
Assert-Equal 6 $calls.Count "replace is write, get, stop, unregister, register, start"
Write-Host "PASS: keepalive registration"
