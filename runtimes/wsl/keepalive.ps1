param(
    [string]$DistroName = "openhands-worker",
    [string]$TaskName = "openhands-worker-keepalive"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-KeepaliveArguments {
    param([Parameter(Mandatory)][string]$Distro)

    if ($Distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Distribution name '$Distro' is not valid."
    }
    return "-d $Distro --user root --exec /bin/sleep infinity"
}

function Register-WorkerKeepalive {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$WslPath,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][scriptblock]$GetTask,
        [Parameter(Mandatory)][scriptblock]$UnregisterTask,
        [Parameter(Mandatory)][scriptblock]$RegisterTask,
        [Parameter(Mandatory)][scriptblock]$StartTask
    )

    $arguments = Get-KeepaliveArguments -Distro $Distro
    if (& $GetTask $Name) {
        & $UnregisterTask $Name
    }
    & $RegisterTask $Name $WslPath $arguments $UserId
    & $StartTask $Name
}

if ($MyInvocation.InvocationName -ne ".") {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Elevated PowerShell is required."
    }
    $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
    Register-WorkerKeepalive -Name $TaskName -Distro $DistroName -WslPath $wsl -UserId $identity.Name `
        -GetTask { param($name) Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } `
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
    Write-Host "Keepalive task '$TaskName' registered for '$DistroName' at logon of $($identity.Name) and started."
}
