[CmdletBinding()]
param(
    [string]$Distribution = "Ubuntu-26.04"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Set-WslMirroredNetworking {
    param([Parameter(Mandatory)][string]$Path)

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $original = if ($exists) { [System.IO.File]::ReadAllText($Path) } else { "" }
    $newline = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
    $hasTrailingNewline = $original.EndsWith("`n")
    $lines = [System.Collections.Generic.List[string]]::new()
    if ($original.Length) {
        $lines.AddRange([string[]]($original -split "`r?`n"))
        if ($lines[$lines.Count - 1] -eq "") {
            $lines.RemoveAt($lines.Count - 1)
        }
    }

    $sections = @{}
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*\[([^\]]+)\]\s*(?:[;#].*)?$') {
            $name = $Matches[1].Trim()
            if ($sections.ContainsKey($name)) {
                throw "Duplicate section [$name] in '$Path'."
            }
            $sections[$name] = $index
        }
    }

    $wsl2Name = $sections.Keys | Where-Object { $_ -ieq "wsl2" } | Select-Object -First 1
    if ($null -eq $wsl2Name) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -ne "") {
            $lines.Add("")
        }
        $lines.Add("[wsl2]")
        $lines.Add("networkingMode=mirrored")
        $lines.Add("dnsTunneling=true")
    }
    else {
        $sectionIndex = [int]$sections[$wsl2Name]
        $start = $sectionIndex + 1
        $end = $lines.Count
        foreach ($sectionStart in $sections.Values) {
            if ($sectionStart -gt $sectionIndex -and $sectionStart -lt $end) {
                $end = $sectionStart
            }
        }

        $keys = @{}
        for ($index = $start; $index -lt $end; $index++) {
            if ($lines[$index] -match '^\s*([^=;#][^=]*)=') {
                $key = $Matches[1].Trim()
                if ($keys.ContainsKey($key)) {
                    throw "Duplicate key '$key' in [wsl2] in '$Path'."
                }
                $keys[$key] = $index
            }
        }

        foreach ($setting in @(@("networkingMode", "mirrored"), @("dnsTunneling", "true"))) {
            $key = $setting[0]
            $value = $setting[1]
            $keyName = $keys.Keys | Where-Object { $_ -ieq $key } | Select-Object -First 1
            if ($null -eq $keyName) {
                $lines.Insert($end, "$key=$value")
                $end++
            }
            elseif ($lines[[int]$keys[$keyName]] -notmatch ("^\\s*" + [regex]::Escape($keyName) + "\\s*=\\s*" + [regex]::Escape($value) + "\\s*(?:[;#].*)?$") ) {
                $lines[[int]$keys[$keyName]] = "$key=$value"
            }
        }
    }

    $updated = ($lines -join $newline) + $(if (-not $original.Length -or $hasTrailingNewline) { $newline } else { "" })
    if ($updated -eq $original) {
        return [pscustomobject]@{ Changed = $false; BackupPath = $null }
    }

    $directory = Split-Path -Parent $Path
    if (-not $directory) {
        $directory = "."
    }
    $leaf = Split-Path -Leaf $Path
    $backupPath = $null
    if ($exists) {
        $backupPath = Join-Path $directory ("$leaf." + (Get-Date -Format "yyyyMMddHHmmssfff") + ".bak")
        [System.IO.File]::Copy($Path, $backupPath)
    }

    $temporaryPath = Join-Path $directory (".$leaf." + [Guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $updated, $encoding)
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }

    return [pscustomobject]@{ Changed = $true; BackupPath = $backupPath }
}

function Assert-WslPrerequisites {
    param([Parameter(Mandatory)][string]$Distribution)

    if (-not [System.Environment]::IsWindowsVersionAtLeast(10, 0, 22621)) {
        throw "Windows build 22621 or later is required."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this installer from an elevated PowerShell session."
    }

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "WSL is not installed or wsl.exe is not available."
    }

    & wsl.exe --version
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read the installed WSL version."
    }

    $online = & wsl.exe --list --online
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list online WSL distributions."
    }
    if (($online -join "`n") -notmatch ("(?m)^\\s*" + [regex]::Escape($Distribution) + "(?:\\s|$)")) {
        throw "Required online WSL distribution '$Distribution' is unavailable."
    }
}

Assert-WslPrerequisites -Distribution $Distribution

$configPath = Join-Path $env:USERPROFILE ".wslconfig"
$result = Set-WslMirroredNetworking -Path $configPath
if ($result.Changed) {
    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "WSL configuration changed, but WSL shutdown failed."
    }
}

Write-Host "WSL bootstrap Stage 1 completed."
