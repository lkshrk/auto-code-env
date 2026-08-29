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

function Import-ConfigMergeFunction {
    param([string]$Path)

    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) {
        throw ($errors | Out-String)
    }

    $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq "Set-WslMirroredNetworking" }, $true)
    if (-not $function) {
        throw "Set-WslMirroredNetworking is missing."
    }

    return $function.Extent.Text
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("wsl-install-tests-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    . ([scriptblock]::Create((Import-ConfigMergeFunction (Join-Path $PSScriptRoot ".." "install.ps1"))))

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

    Write-Host "PASS: WSL mirrored networking configuration"
}
finally {
    Remove-Item -Recurse -Force $testRoot -ErrorAction SilentlyContinue
}
