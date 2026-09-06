$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    Install-Module -Name PSScriptAnalyzer -RequiredVersion 1.23.0 -Scope CurrentUser -Force -AllowClobber
}
Import-Module PSScriptAnalyzer -RequiredVersion 1.23.0

$windows51 = "win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework"
$settings = @{
    IncludeRules = @("PSUseCompatibleSyntax", "PSUseCompatibleCommands", "PSUseCompatibleTypes")
    Rules = @{
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @("5.1", "7.4") }
        PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @($windows51) }
        PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @($windows51) }
    }
}
$scripts = Get-ChildItem -Path (Join-Path $PSScriptRoot "..\install") -Filter *.ps1
$denied = @(
    @{ Pattern = '\.ArgumentList\b'; Message = "ProcessStartInfo.ArgumentList is .NET Core only; build Arguments instead" },
    @{ Pattern = '-AsHashtable\b'; Message = "ConvertFrom-Json -AsHashtable is PowerShell 7 only" },
    @{ Pattern = '-LeafBase\b'; Message = "Split-Path -LeafBase is PowerShell 7 only" },
    @{ Pattern = '\$IsWindows\b|\$IsLinux\b|\$IsMacOS\b'; Message = "platform automatic variables are PowerShell 7 only" },
    @{ Pattern = '\?\?'; Message = "null-coalescing operators are PowerShell 7 only" },
    @{ Pattern = 'ForEach-Object\s+-Parallel'; Message = "ForEach-Object -Parallel is PowerShell 7 only" }
)
$findings = @()
foreach ($script in $scripts) {
    $findings += Invoke-ScriptAnalyzer -Path $script.FullName -Settings $settings
    $line = 0
    foreach ($text in Get-Content -LiteralPath $script.FullName) {
        $line++
        foreach ($rule in $denied) {
            if ($text -match $rule.Pattern) {
                $findings += [pscustomobject]@{ RuleName = "WorkerDenylist"; ScriptName = $script.Name; Line = $line; Message = $rule.Message }
            }
        }
    }
}
if ($findings.Count -gt 0) {
    $findings | Format-Table RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    throw "$($findings.Count) Windows PowerShell 5.1 compatibility finding(s)."
}
Write-Host "PASS: worker/windows scripts are Windows PowerShell 5.1 compatible ($($scripts.Count) files)"
