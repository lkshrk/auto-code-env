param(
    [Parameter(Mandatory)][string[]]$RemoteAddresses,
    [int]$Port = 443
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$WslVmCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
$RuleName = "openhands-worker-https"
$RuleDisplayName = "OpenHands worker HTTPS"

function Test-TrustedRemoteAddress {
    param([Parameter(Mandatory)][string]$Address)

    $trimmed = $Address.Trim()
    if ($trimmed -eq "" -or $trimmed -eq "Any" -or $trimmed -eq "*") {
        return $false
    }
    $ipv4 = "^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$"
    if ($trimmed -match "^(?<host>[^/]+)/(?<prefix>\d{1,2})$") {
        $prefix = [int]$Matches.prefix
        return ($Matches.host -match $ipv4) -and $prefix -ge 24 -and $prefix -le 32
    }
    return $trimmed -match $ipv4
}

function Get-TrustedRemoteAddresses {
    param([Parameter(Mandatory)][string[]]$Addresses)

    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($address in $Addresses) {
        foreach ($item in ($address -split ",")) {
            $trimmed = $item.Trim()
            if ($trimmed -eq "") {
                continue
            }
            if (-not (Test-TrustedRemoteAddress -Address $trimmed)) {
                throw "Remote address '$trimmed' is not a single IPv4 host or a /24 or narrower IPv4 range."
            }
            if (-not $result.Contains($trimmed)) {
                $result.Add($trimmed)
            }
        }
    }
    if ($result.Count -eq 0) {
        throw "At least one trusted remote address is required."
    }
    return $result.ToArray()
}

function Set-WorkerFirewallRules {
    param(
        [Parameter(Mandatory)][string[]]$Remote,
        [Parameter(Mandatory)][int]$LocalPort,
        [Parameter(Mandatory)][scriptblock]$GetHostRule,
        [Parameter(Mandatory)][scriptblock]$NewHostRule,
        [Parameter(Mandatory)][scriptblock]$SetHostRule,
        [Parameter(Mandatory)][scriptblock]$SetVmDefault,
        [Parameter(Mandatory)][scriptblock]$GetVmRule,
        [Parameter(Mandatory)][scriptblock]$NewVmRule,
        [Parameter(Mandatory)][scriptblock]$TestVmRule,
        [Parameter(Mandatory)][scriptblock]$RemoveVmRule
    )

    if ($LocalPort -ne 443) {
        throw "Only TCP/443 may be exposed."
    }

    & $SetVmDefault $WslVmCreatorId

    $existingHost = & $GetHostRule $RuleName
    if ($existingHost) {
        & $SetHostRule $RuleName $LocalPort $Remote
    }
    else {
        & $NewHostRule $RuleName $RuleDisplayName $LocalPort $Remote
    }

    $existingVm = & $GetVmRule $RuleName
    if ($existingVm) {
        if (& $TestVmRule $existingVm $LocalPort $Remote) {
            return
        }
        & $RemoveVmRule $RuleName
    }
    & $NewVmRule $RuleName $RuleDisplayName $WslVmCreatorId $LocalPort $Remote
}

function Test-VmRuleMatches {
    param($Rule, [int]$LocalPort, [string[]]$Remote)

    $expectedRemote = ($Remote | Sort-Object) -join ","
    $actualRemote = (@($Rule.RemoteAddresses) | Sort-Object) -join ","
    return ("$($Rule.Enabled)" -eq "True") -and ("$($Rule.Direction)" -eq "Inbound") -and ("$($Rule.Action)" -eq "Allow") -and
        ("$($Rule.Protocol)" -eq "TCP") -and ((@($Rule.LocalPorts) -join ",") -eq "$LocalPort") -and ($actualRemote -eq $expectedRemote)
}

if ($MyInvocation.InvocationName -ne ".") {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Elevated PowerShell is required."
    }
    $remote = Get-TrustedRemoteAddresses -Addresses $RemoteAddresses
    Set-WorkerFirewallRules -Remote $remote -LocalPort $Port `
        -GetHostRule { param($name) Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue } `
        -NewHostRule { param($name, $display, $port, $addresses) New-NetFirewallRule -Name $name -DisplayName $display -Direction Inbound -Protocol TCP -LocalPort $port -RemoteAddress $addresses -Action Allow -Profile Any | Out-Null } `
        -SetHostRule { param($name, $port, $addresses) Set-NetFirewallRule -Name $name -Direction Inbound -Protocol TCP -LocalPort $port -RemoteAddress $addresses -Action Allow -Profile Any -Enabled True } `
        -SetVmDefault { param($creator) Set-NetFirewallHyperVVMSetting -Name $creator -DefaultInboundAction Block } `
        -GetVmRule { param($name) Get-NetFirewallHyperVRule -Name $name -ErrorAction SilentlyContinue } `
        -NewVmRule { param($name, $display, $creator, $port, $addresses) New-NetFirewallHyperVRule -Name $name -DisplayName $display -Direction Inbound -VMCreatorId $creator -Protocol TCP -LocalPorts $port -RemoteAddresses $addresses -Action Allow | Out-Null } `
        -TestVmRule { param($rule, $port, $addresses) Test-VmRuleMatches -Rule $rule -LocalPort $port -Remote $addresses } `
        -RemoveVmRule { param($name) Remove-NetFirewallHyperVRule -Name $name }
    Write-Host "Inbound TCP/$Port allowed from: $($remote -join ', '). All other inbound traffic to WSL is blocked."
}
