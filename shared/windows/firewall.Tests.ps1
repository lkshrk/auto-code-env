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
if ($source -notmatch '\[int\[\]\]\$AllowedPorts = @\(443, 2376\)') {
    throw "The exposable port allowlist must be exactly 443 and 2376."
}
if ($source -notmatch '\$RuleName = "openhands-worker-https"') {
    throw "RuleName must default to the released worker rule name."
}
if ($source -notmatch '\$RuleDisplayName = "OpenHands worker HTTPS"') {
    throw "RuleDisplayName must default to the released worker rule display name."
}
foreach ($name in "Test-TrustedRemoteAddress", "Get-TrustedRemoteAddresses", "Set-WorkerFirewallRules", "Test-VmRuleMatches") {
    Invoke-Expression (Import-ScriptFunction -Path $scriptPath -Name $name)
}
$WslVmCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
$RuleName = "openhands-worker-https"
$RuleDisplayName = "OpenHands worker HTTPS"
$CoderRuleName = "coder-worker-docker"
$CoderRuleDisplayName = "Coder worker Docker"

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

Set-WorkerFirewallRules -Name $RuleName -DisplayName $RuleDisplayName -Remote @("10.254.0.10", "10.254.0.11") -LocalPort 443 @common
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
Set-WorkerFirewallRules -Name $RuleName -DisplayName $RuleDisplayName -Remote @("10.254.0.99") -LocalPort 443 @common
Assert-Equal "set-host openhands-worker-https 443 10.254.0.99" $calls[2] "existing host rule is updated in place"
Assert-Equal "test-vm 443 10.254.0.99" $calls[4] "existing vm rule is compared"
Assert-Equal 5 $calls.Count "matching vm rule is left untouched"

$calls.Clear()
$vmMatches = $false
Set-WorkerFirewallRules -Name $RuleName -DisplayName $RuleDisplayName -Remote @("10.254.0.99") -LocalPort 443 @common
Assert-Equal "remove-vm openhands-worker-https" $calls[5] "differing vm rule is removed"
Assert-Equal "new-vm openhands-worker-https {40E0AC32-46A5-438A-A0B2-2B479E8F2E90} 443 10.254.0.99" $calls[6] "differing vm rule is recreated"
Write-Host "PASS: idempotent rule management"

$calls.Clear()
$hostExists = $false
$vmExists = $false
Set-WorkerFirewallRules -Name $CoderRuleName -DisplayName $CoderRuleDisplayName -Remote @("10.254.0.20") -LocalPort 2376 @common
Assert-Equal "new-host coder-worker-docker Coder worker Docker 2376 10.254.0.20" $calls[2] "the docker rule is created under its own name"
Assert-Equal "new-vm coder-worker-docker {40E0AC32-46A5-438A-A0B2-2B479E8F2E90} 2376 10.254.0.20" $calls[4] "the docker vm rule is created under its own name"
foreach ($call in $calls) {
    if ($call -match [regex]::Escape($RuleName)) {
        throw "Creating the docker rule touched '$RuleName': $call"
    }
}
Write-Host "PASS: the docker rule never names the worker rule"

$calls.Clear()
Assert-Throws { Set-WorkerFirewallRules -Name $CoderRuleName -DisplayName $CoderRuleDisplayName -Remote @("10.254.0.20") -LocalPort 8000 @common } "Only TCP/443 and TCP/2376" "port 8000 is refused"
Assert-Throws { Set-WorkerFirewallRules -Name $CoderRuleName -DisplayName $CoderRuleDisplayName -Remote @("10.254.0.20") -LocalPort 22 @common } "Only TCP/443 and TCP/2376" "port 22 is refused"
Assert-Throws { Set-WorkerFirewallRules -Name $CoderRuleName -DisplayName $CoderRuleDisplayName -Remote @("10.254.0.20") -LocalPort 2375 @common } "Only TCP/443 and TCP/2376" "the plaintext docker port is refused"
Assert-Throws { Set-WorkerFirewallRules -Name "coder worker docker" -DisplayName $CoderRuleDisplayName -Remote @("10.254.0.20") -LocalPort 2376 @common } "is not valid" "an invalid rule name is refused"
Assert-Equal 0 $calls.Count "a refused rule makes no firewall call"
Write-Host "PASS: only the allowlisted ports are exposable"

$hostRules = @{}
$vmRules = @{}
$removals = New-Object 'System.Collections.Generic.List[string]'
$store = @{
    GetHostRule  = { param($name) if ($hostRules.ContainsKey($name)) { $hostRules[$name] } }
    NewHostRule  = { param($name, $display, $port, $addresses) $hostRules[$name] = [pscustomobject]@{ DisplayName = $display; LocalPorts = @("$port"); RemoteAddresses = @($addresses) } }
    SetHostRule  = { param($name, $port, $addresses) $hostRules[$name].LocalPorts = @("$port"); $hostRules[$name].RemoteAddresses = @($addresses) }
    SetVmDefault = { param($creator) }
    GetVmRule    = { param($name) if ($vmRules.ContainsKey($name)) { $vmRules[$name] } }
    NewVmRule    = { param($name, $display, $creator, $port, $addresses) $vmRules[$name] = [pscustomobject]@{ Enabled = "True"; Direction = "Inbound"; Action = "Allow"; Protocol = "TCP"; DisplayName = $display; LocalPorts = @("$port"); RemoteAddresses = @($addresses) } }
    TestVmRule   = { param($rule, $port, $addresses) Test-VmRuleMatches -Rule $rule -LocalPort $port -Remote $addresses }
    RemoveVmRule = { param($name) $removals.Add($name); $vmRules.Remove($name) }
}

Set-WorkerFirewallRules -Name $RuleName -DisplayName $RuleDisplayName -Remote @("10.254.0.10", "10.254.0.11") -LocalPort 443 @store
Set-WorkerFirewallRules -Name $CoderRuleName -DisplayName $CoderRuleDisplayName -Remote @("10.254.0.20") -LocalPort 2376 @store
Assert-Equal 2 $vmRules.Count "both Hyper-V rules coexist"
Assert-Equal 2 $hostRules.Count "both host rules coexist"
Assert-Equal "443" ($vmRules[$RuleName].LocalPorts -join ",") "the worker rule keeps TCP/443"
Assert-Equal "10.254.0.10,10.254.0.11" ($vmRules[$RuleName].RemoteAddresses -join ",") "the worker rule keeps its sources"
Assert-Equal "OpenHands worker HTTPS" $vmRules[$RuleName].DisplayName "the worker rule keeps its display name"
Assert-Equal "2376" ($vmRules[$CoderRuleName].LocalPorts -join ",") "the docker rule owns TCP/2376"
Assert-Equal "10.254.0.20" ($vmRules[$CoderRuleName].RemoteAddresses -join ",") "the docker rule owns its sources"
Assert-Equal 0 $removals.Count "adding the docker rule removed nothing"

Set-WorkerFirewallRules -Name $RuleName -DisplayName $RuleDisplayName -Remote @("10.254.0.10", "10.254.0.11") -LocalPort 443 @store
Assert-Equal 0 $removals.Count "re-running the worker rule removed nothing"
Assert-Equal "2376" ($vmRules[$CoderRuleName].LocalPorts -join ",") "re-running the worker rule left the docker rule alone"
Assert-Equal "10.254.0.20" ($vmRules[$CoderRuleName].RemoteAddresses -join ",") "re-running the worker rule left the docker sources alone"
Write-Host "PASS: two products own two independent rules"
