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

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wsl-install-tests-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    $installPath = Join-Path $PSScriptRoot ".." "install.ps1"
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Set-WslMirroredNetworking")))
    . ([scriptblock]::Create((Import-InstallFunction $installPath "Test-WslDistributionAvailable")))

    $onlineOutput = @(
        "The following is a list of valid distributions that can be installed.",
        "Install using 'wsl.exe --install <Distro>'.",
        "",
        "NAME                            FRIENDLY NAME",
        "Ubuntu-26.04                    Ubuntu 26.04 LTS"
    )
    Assert-Equal $true (Test-WslDistributionAvailable -Output $onlineOutput -Distribution "Ubuntu-26.04") "exact online distribution should be available"
    Assert-Equal $false (Test-WslDistributionAvailable -Output @("Ubuntu-26.04-extra             Wrong") -Distribution "Ubuntu-26.04") "near-match distribution should be unavailable"

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

    $source = Get-Content $installPath -Raw
    Assert-NotMatch 'IsWindowsVersionAtLeast|File\]::Move\([^\r\n]+,\s*[^\r\n]+,\s*\$true\)|::new\(' $source "Windows PowerShell 5.1 compatibility"

    Write-Host "PASS: WSL mirrored networking configuration"
}
finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}
