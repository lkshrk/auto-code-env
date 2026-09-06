param(
    [string]$DistroName = "openhands-worker",
    [string]$TaskName = "openhands-worker-keepalive"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-KeepaliveLauncherContent {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$WslPath
    )

    if ($Distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Distribution name '$Distro' is not valid."
    }
    if ($WslPath -match '["&|<>^]') {
        throw "wsl.exe path '$WslPath' contains characters that cannot be launched safely."
    }
    $command = '"' + $WslPath + '" -d ' + $Distro + ' --user root --exec /bin/sleep infinity'
    return 'CreateObject("WScript.Shell").Run "' + $command.Replace('"', '""') + '", 0, True'
}

function Get-KeepaliveArguments {
    param([Parameter(Mandatory)][string]$LauncherPath)

    if ($LauncherPath -match '"') {
        throw "Launcher path '$LauncherPath' must not contain quotes."
    }
    return "//B //Nologo `"$LauncherPath`""
}

function Register-WorkerKeepalive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$HostPath,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][scriptblock]$WriteLauncher,
        [Parameter(Mandatory)][scriptblock]$GetTask,
        [Parameter(Mandatory)][scriptblock]$StopTask,
        [Parameter(Mandatory)][scriptblock]$UnregisterTask,
        [Parameter(Mandatory)][scriptblock]$RegisterTask,
        [Parameter(Mandatory)][scriptblock]$StartTask
    )

    & $WriteLauncher $LauncherPath (Get-KeepaliveLauncherContent -Distro $Distro -WslPath $WslPath)
    $arguments = Get-KeepaliveArguments -LauncherPath $LauncherPath
    if (& $GetTask $Name) {
        & $StopTask $Name
        & $UnregisterTask $Name
    }
    & $RegisterTask $Name $HostPath $arguments $UserId
    & $StartTask $Name
}

if ($MyInvocation.InvocationName -ne ".") {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Elevated PowerShell is required."
    }
    $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
    $hostExe = Join-Path $env:SystemRoot "System32\wscript.exe"
    $launcherDir = Join-Path $env:ProgramData "openhands-worker"
    $launcherPath = Join-Path $launcherDir "keepalive-$DistroName.vbs"
    Register-WorkerKeepalive -Name $TaskName -Distro $DistroName -WslPath $wsl -HostPath $hostExe -LauncherPath $launcherPath -UserId $identity.Name `
        -WriteLauncher {
            param($path, $content)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllText($path, $content + "`r`n", (New-Object System.Text.ASCIIEncoding))
        } `
        -GetTask { param($name) Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } `
        -StopTask { param($name) Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } `
        -UnregisterTask { param($name) Unregister-ScheduledTask -TaskName $name -Confirm:$false } `
        -RegisterTask {
            param($name, $exe, $arguments, $user)
            $action = New-ScheduledTaskAction -Execute $exe -Argument $arguments
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
        } `
        -StartTask { param($name) Start-ScheduledTask -TaskName $name }
    Write-Host "Keepalive task '$TaskName' registered for '$DistroName' at logon of $($identity.Name) (windowless via wscript) and started."
}
