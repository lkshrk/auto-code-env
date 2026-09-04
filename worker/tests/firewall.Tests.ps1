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

$scriptPath = Join-Path $PSScriptRoot "..\windows\firewall.ps1"
$source = Get-Content -Raw $scriptPath
if ($source -notmatch '\[Parameter\(Mandatory\)\]\[string\[\]\]\$RemoteAddresses') {
    throw "RemoteAddresses must be mandatory."
}
if ($source -match 'RemoteAddress(es)?\s+(Any|\*|0\.0\.0\.0/0)') {
    throw "firewall.ps1 must never allow any source."
}
if ($source -notmatch '40E0AC32-46A5-438A-A0B2-2B479E8F2E90') {
    throw "WSL Hyper-V VM creator id is missing."
}
if ($source -notmatch 'DefaultInboundAction Block') {
    throw "Hyper-V default inbound action must be Block."
}
foreach ($name in "Test-TrustedRemoteAddress", "Get-TrustedRemoteAddresses", "Set-WorkerFirewallRules", "Test-VmRuleMatches") {
    Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name $name)
}
$WslVmCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
$RuleName = "openhands-worker-https"
$RuleDisplayName = "OpenHands worker HTTPS"

Assert-Equal $true (Test-TrustedRemoteAddress -Address "10.254.0.10") "single IPv4 host"
Assert-Equal $true (Test-TrustedRemoteAddress -Address "10.254.0.0/24") "/24 range"
Assert-Equal $false (Test-TrustedRemoteAddress -Address "10.254.0.0/16") "/16 range is too broad"
Assert-Equal $false (Test-TrustedRemoteAddress -Address "Any") "Any is rejected"
Assert-Equal $false (Test-TrustedRemoteAddress -Address "*") "wildcard is rejected"
Assert-Equal $false (Test-TrustedRemoteAddress -Address "0.0.0.0/0") "default route is rejected"
Assert-Equal $false (Test-TrustedRemoteAddress -Address "fd00::1") "IPv6 is not accepted"
Assert-Equal $false (Test-TrustedRemoteAddress -Address "10.254.0") "partial address is rejected"
Write-Host "PASS: trusted address validation"

$parsed = Get-TrustedRemoteAddresses -Addresses @("10.254.0.10, 10.254.0.11", "10.254.0.99", "10.254.0.10")
Assert-Equal 3 $parsed.Count "comma lists are split and deduplicated"
Assert-Equal "10.254.0.99" $parsed[2] "order is preserved"
Assert-Throws { Get-TrustedRemoteAddresses -Addresses @("172.16.20.0/16") } "not a single IPv4 host" "broad range throws"
Assert-Throws { Get-TrustedRemoteAddresses -Addresses @(" ", ",") } "At least one" "blank list throws"
Write-Host "PASS: remote address parsing"

$matching = [pscustomobject]@{ Enabled = "True"; Direction = "Inbound"; Action = "Allow"; Protocol = "TCP"; LocalPorts = @("443"); RemoteAddresses = @("10.254.0.11", "10.254.0.10") }
Assert-Equal $true (Test-VmRuleMatches -Rule $matching -LocalPort 443 -Remote @("10.254.0.10", "10.254.0.11")) "order-insensitive match"
Assert-Equal $false (Test-VmRuleMatches -Rule $matching -LocalPort 443 -Remote @("10.254.0.10")) "extra source does not match"
Assert-Equal $false (Test-VmRuleMatches -Rule $matching -LocalPort 8000 -Remote @("10.254.0.10", "10.254.0.11")) "other port does not match"
$disabled = [pscustomobject]@{ Enabled = "False"; Direction = "Inbound"; Action = "Allow"; Protocol = "TCP"; LocalPorts = @("443"); RemoteAddresses = @("10.254.0.10", "10.254.0.11") }
Assert-Equal $false (Test-VmRuleMatches -Rule $disabled -LocalPort 443 -Remote @("10.254.0.10", "10.254.0.11")) "disabled rule does not match"
Write-Host "PASS: Hyper-V rule comparison"

$calls = New-Object 'System.Collections.Generic.List[string]'
$hostExists = $false
$vmExists = $false
$vmMatches = $false
$common = @{
    GetHostRule  = { param($name) $calls.Add("get-host $name"); if ($hostExists) { "rule" } }
    NewHostRule  = { param($name, $display, $port, $addresses) $calls.Add("new-host $name $display $port $($addresses -join ',')") }
    SetHostRule  = { param($name, $port, $addresses) $calls.Add("set-host $name $port $($addresses -join ',')") }
    SetVmDefault = { param($creator) $calls.Add("vm-default $creator") }
    GetVmRule    = { param($name) $calls.Add("get-vm $name"); if ($vmExists) { "rule" } }
    NewVmRule    = { param($name, $display, $creator, $port, $addresses) $calls.Add("new-vm $name $creator $port $($addresses -join ',')") }
    TestVmRule   = { param($rule, $port, $addresses) $calls.Add("test-vm $port $($addresses -join ',')"); $vmMatches }
    RemoveVmRule = { param($name) $calls.Add("remove-vm $name") }
}

Set-WorkerFirewallRules -Remote @("10.254.0.10", "10.254.0.11") -LocalPort 443 @common
Assert-Equal "vm-default {40E0AC32-46A5-438A-A0B2-2B479E8F2E90}" $calls[0] "Hyper-V default block is applied first"
Assert-Equal "get-host openhands-worker-https" $calls[1] "host rule lookup"
Assert-Equal "new-host openhands-worker-https OpenHands worker HTTPS 443 10.254.0.10,10.254.0.11" $calls[2] "host rule created with exact sources"
Assert-Equal "get-vm openhands-worker-https" $calls[3] "vm rule lookup"
Assert-Equal "new-vm openhands-worker-https {40E0AC32-46A5-438A-A0B2-2B479E8F2E90} 443 10.254.0.10,10.254.0.11" $calls[4] "vm rule created with exact sources"
Assert-Equal 5 $calls.Count "no extra firewall calls"

$calls.Clear()
$hostExists = $true
$vmExists = $true
$vmMatches = $true
Set-WorkerFirewallRules -Remote @("10.254.0.99") -LocalPort 443 @common
Assert-Equal "set-host openhands-worker-https 443 10.254.0.99" $calls[2] "existing host rule is updated in place"
Assert-Equal "test-vm 443 10.254.0.99" $calls[4] "existing vm rule is compared"
Assert-Equal 5 $calls.Count "matching vm rule is left untouched"

$calls.Clear()
$vmMatches = $false
Set-WorkerFirewallRules -Remote @("10.254.0.99") -LocalPort 443 @common
Assert-Equal "remove-vm openhands-worker-https" $calls[5] "differing vm rule is removed"
Assert-Equal "new-vm openhands-worker-https {40E0AC32-46A5-438A-A0B2-2B479E8F2E90} 443 10.254.0.99" $calls[6] "differing vm rule is recreated"
Write-Host "PASS: idempotent rule management"

$calls.Clear()
Assert-Throws { Set-WorkerFirewallRules -Remote @("10.254.0.99") -LocalPort 8000 @common } "Only TCP/443" "port 8000 is refused"
Assert-Equal 0 $calls.Count "refused port makes no firewall call"
Write-Host "PASS: only 443 is exposable"
