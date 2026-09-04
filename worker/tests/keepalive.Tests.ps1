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
foreach ($required in '-ExecutionTimeLimit \(\[TimeSpan\]::Zero\)', '-MultipleInstances IgnoreNew', '-Hidden', '-DontStopIfGoingOnBatteries', '-RunLevel Limited', '-AtLogOn', 'Start-ScheduledTask') {
    if ($source -notmatch $required) {
        throw "keepalive.ps1 must use $required."
    }
}
if ($source -match 'RunLevel Highest') {
    throw "keepalive must not run elevated."
}
foreach ($name in "Get-KeepaliveArguments", "Register-WorkerKeepalive") {
    Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name $name)
}

Assert-Equal "-d openhands-worker --user root --exec /bin/sleep infinity" (Get-KeepaliveArguments -Distro "openhands-worker") "keepalive runs an unprivileged-in-Windows sleep as root inside the distro"
Assert-Throws { Get-KeepaliveArguments -Distro "bad name; rm" } "not valid" "distro names with shell characters are refused"
Write-Host "PASS: keepalive arguments"

$calls = New-Object 'System.Collections.Generic.List[string]'
$exists = $false
$common = @{
    GetTask        = { param($name) $calls.Add("get $name"); if ($exists) { "task" } }
    UnregisterTask = { param($name) $calls.Add("unregister $name") }
    RegisterTask   = { param($name, $exe, $arguments, $user) $calls.Add("register $name $exe [$arguments] $user") }
    StartTask      = { param($name) $calls.Add("start $name") }
}

Register-WorkerKeepalive -Name "openhands-worker-keepalive" -Distro "openhands-worker" -WslPath "C:\Windows\System32\wsl.exe" -UserId "TOWERR\op" @common
Assert-Equal "get openhands-worker-keepalive" $calls[0] "existing task lookup"
Assert-Equal "register openhands-worker-keepalive C:\Windows\System32\wsl.exe [-d openhands-worker --user root --exec /bin/sleep infinity] TOWERR\op" $calls[1] "task registered with exact wsl arguments and user"
Assert-Equal "start openhands-worker-keepalive" $calls[2] "task started immediately"
Assert-Equal 3 $calls.Count "no unregister when task is new"

$calls.Clear()
$exists = $true
Register-WorkerKeepalive -Name "openhands-worker-keepalive" -Distro "openhands-worker" -WslPath "C:\Windows\System32\wsl.exe" -UserId "TOWERR\op" @common
Assert-Equal "unregister openhands-worker-keepalive" $calls[1] "existing task is replaced"
Assert-Equal 4 $calls.Count "replace is get, unregister, register, start"
Write-Host "PASS: keepalive registration"
