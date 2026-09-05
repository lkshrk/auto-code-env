[CmdletBinding()]
param(
    [string]$Config,
    [string]$Release,
    [System.Security.SecureString]$VaultPassword,
    [string]$TaskName = "openhands-worker-update",
    [switch]$Force,
    [switch]$Schedule
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

function Get-WorkerStagingDistroName {
    param([Parameter(Mandatory)][string]$Distro)

    $staging = "$Distro-next"
    if ($staging -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Staging distribution name '$staging' is not valid."
    }
    return $staging
}

function Get-WorkerUpdateTaskArguments {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )

    foreach ($value in @($ScriptPath, $ConfigPath)) {
        if ($value.Contains('"')) {
            throw "Path '$value' cannot be used in a scheduled task argument."
        }
    }
    return "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" -Config `"$ConfigPath`" -Release latest"
}

function Register-WorkerUpdateTask {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][scriptblock]$GetTask,
        [Parameter(Mandatory)][scriptblock]$UnregisterTask,
        [Parameter(Mandatory)][scriptblock]$RegisterTask
    )

    $arguments = Get-WorkerUpdateTaskArguments -ScriptPath $ScriptPath -ConfigPath $ConfigPath
    if (& $GetTask $Name) {
        & $UnregisterTask $Name
    }
    & $RegisterTask $Name $arguments $UserId
}

function Test-WorkerStateArchive {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][scriptblock]$ListArchive
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "State archive '$Path' was not written."
    }
    if ((Get-Item -LiteralPath $Path -Force).Length -eq 0) {
        throw "State archive '$Path' is empty."
    }
    $entries = @(& $ListArchive $Path)
    if ($entries.Count -eq 0) {
        throw "State archive '$Path' has no entries."
    }
    return $entries.Count
}

function Remove-WorkerStateArchive {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Keep
    )

    $keepName = [IO.Path]::GetFileName($Keep)
    foreach ($item in @(Get-ChildItem -LiteralPath $Directory -Filter "state-*.tar.gz" -File -ErrorAction SilentlyContinue)) {
        if ($item.Name -cne $keepName) {
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Update-WorkerDistribution {
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$Staging,
        [Parameter(Mandatory)][scriptblock]$InstallStaging,
        [Parameter(Mandatory)][scriptblock]$ProvisionStaging,
        [Parameter(Mandatory)][scriptblock]$StopDistribution,
        [Parameter(Mandatory)][scriptblock]$ActivateStaging,
        [Parameter(Mandatory)][scriptblock]$ResolveDistribution,
        [Parameter(Mandatory)][scriptblock]$UnregisterDistribution,
        [Parameter(Mandatory)][scriptblock]$RenameDistribution,
        [Parameter(Mandatory)][scriptblock]$RestoreDistribution,
        [Parameter(Mandatory)][scriptblock]$Finalize
    )

    $installed = $false
    $stopped = $false
    try {
        & $InstallStaging $Staging
        $installed = $true
        & $ProvisionStaging $Staging
        & $StopDistribution $Distro
        $stopped = $true
        & $ActivateStaging $Staging
    }
    catch {
        if ($installed) {
            try { & $StopDistribution $Staging } catch { Write-Warning $_.Exception.Message }
            try { & $UnregisterDistribution $Staging } catch { Write-Warning $_.Exception.Message }
        }
        if ($stopped) {
            try { & $RestoreDistribution $Distro } catch { Write-Warning $_.Exception.Message }
        }
        throw
    }

    $key = & $ResolveDistribution $Staging
    & $StopDistribution $Staging
    & $UnregisterDistribution $Distro
    & $RenameDistribution $key $Distro
    & $Finalize $Distro
}

if ($MyInvocation.InvocationName -ne ".") {
    $identity = Assert-WorkerElevated

    $configPath = Get-WorkerConfigPath -Path $Config
    $configuration = Read-WorkerConfig -Path $configPath

    if ($Schedule) {
        Register-WorkerUpdateTask -Name $TaskName -ScriptPath $PSCommandPath -ConfigPath $configPath -UserId $identity.Name `
            -GetTask { param($name) Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue } `
            -UnregisterTask { param($name) Unregister-ScheduledTask -TaskName $name -Confirm:$false } `
            -RegisterTask {
                param($name, $arguments, $user)
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
                $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 04:00
                $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden
                $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
                Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
            }
        Write-Host "Weekly update task '$TaskName' registered for $($identity.Name)."
        return
    }

    $architecture = if ([string]::IsNullOrWhiteSpace($configuration.Architecture)) { Get-WorkerArchitecture } else { $configuration.Architecture }
    $distro = $configuration.Distro
    $staging = Get-WorkerStagingDistroName -Distro $distro
    $wslPath = Get-WorkerWslPath
    $download = { param($uri, $path) Invoke-WebRequest -Uri $uri -OutFile $path -UseBasicParsing }

    $registered = & $wslPath --list --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list installed WSL distributions."
    }
    if (-not (Test-WorkerDistributionRegistered -Output $registered -Name $distro)) {
        throw "WSL distribution '$distro' is not installed. Run setup.ps1 first."
    }
    if (Test-WorkerDistributionRegistered -Output $registered -Name $staging) {
        throw "Staging distribution '$staging' is left over from a previous run. Remove it with 'wsl --unregister $staging' and try again."
    }

    $tag = if (-not [string]::IsNullOrWhiteSpace($Release)) { $Release } else { $configuration.Release }
    if ($tag -ceq "latest") {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$($configuration.Repository)/releases?per_page=50" -UseBasicParsing
        $tag = Select-WorkerReleaseTag -Releases @($releases)
    }
    $target = Get-WorkerVersionFromTag -Tag $tag

    $marker = & $wslPath --distribution $distro --user root --exec cat /etc/openhands/release
    $current = if ($LASTEXITCODE -eq 0) { Get-WorkerInstalledVersion -Output $marker } else { $null }
    $comparison = Compare-WorkerVersion -Installed $current -Target $target
    $currentLabel = if ($current) { $current } else { "unknown" }
    if ($comparison -eq 0 -and -not $Force) {
        Write-Host "Worker '$distro' is already at $target."
        return
    }
    if ($comparison -gt 0 -and -not $Force) {
        throw "Worker '$distro' runs $currentLabel, which is newer than $target. Pass -Force to install it anyway."
    }
    Write-Host "Updating '$distro' from $currentLabel to $target."

    $credentialPath = Get-WorkerCredentialPath
    $credentialParameters = @{ Path = $credentialPath }
    if ($PSBoundParameters.ContainsKey("VaultPassword")) {
        $credentialParameters["VaultPassword"] = $VaultPassword
    }
    $credential = Get-WorkerVaultCredential @credentialParameters

    $root = Join-Path ([IO.Path]::GetTempPath()) "openhands-worker"
    $assets = Get-WorkerReleaseAssets -Configuration $configuration -Tag $tag -Architecture $architecture `
        -Directory (Join-Path $root $tag) -Download $download
    $profilePath = Resolve-WorkerProfilePath -ProfileAsset $configuration.Profile -Directory (Join-Path $root $tag) -Download $download
    Write-Host "Verified $($assets.Paths.Count) release assets of $tag against checksums.txt."

    Copy-WorkerFileToDistribution -WslPath $wslPath -Distro $distro -Path $assets.Paths["openhands-overlay"] -Destination "/usr/local/sbin/openhands-overlay" -Mode "0755"
    Write-Host "Refreshed openhands-overlay in '$distro' from $tag before exporting state."
    $statePath = Join-Path $root ("state-" + (Get-Date -Format "yyyyMMddHHmmss") + ".tar.gz")
    Invoke-WorkerOverlay -WslPath $wslPath -Distro $distro -Command @("state", "export") -OutputPath $statePath
    $entries = Test-WorkerStateArchive -Path $statePath -ListArchive {
        param($path)
        $listing = & tar.exe --list --file $path
        if ($LASTEXITCODE -ne 0) {
            throw "State archive '$path' is not a readable gzip tar."
        }
        return $listing
    }
    Write-Host "Exported $entries agent state entries to $statePath."

    Update-WorkerDistribution -Distro $distro -Staging $staging `
        -InstallStaging { param($name) & $assets.Paths["install.ps1"] -DistroName $name -ImagePath $assets.Image -ImageSha256 $assets.ImageHash } `
        -ProvisionStaging {
            param($name)
            Wait-WorkerSystemReady -WslPath $wslPath -Distro $name | Out-Null
            Invoke-WorkerProvision -Configuration $configuration -OverlayPath $assets.Paths["openhands-overlay"] `
                -ProfilePath $profilePath -CommonProfilePath $assets.CommonProfile -StatePath $statePath `
                -CopyFile { param($source, $destination, $mode) Copy-WorkerFileToDistribution -WslPath $wslPath -Distro $name -Path $source -Destination $destination -Mode $mode } `
                -Overlay {
                    param($command, $usePassword, $inputPath)
                    $parameters = @{ WslPath = $wslPath; Distro = $name; Command = $command }
                    if ($usePassword) { $parameters["Credential"] = $credential }
                    if ($inputPath) { $parameters["InputPath"] = $inputPath }
                    Invoke-WorkerOverlay @parameters
                }
        } `
        -StopDistribution {
            param($name)
            & $wslPath --terminate $name
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to terminate WSL distribution '$name'."
            }
        } `
        -ActivateStaging {
            param($name)
            Invoke-WorkerActivation -ProfilePaths (Get-WorkerGuestProfilePaths -CommonProfilePath $assets.CommonProfile) -Overlay {
                param($command, $usePassword, $inputPath)
                $parameters = @{ WslPath = $wslPath; Distro = $name; Command = $command }
                if ($usePassword) { $parameters["Credential"] = $credential }
                if ($inputPath) { $parameters["InputPath"] = $inputPath }
                Invoke-WorkerOverlay @parameters
            }
        } `
        -ResolveDistribution {
            param($name)
            Get-WslDistributionRegistryKey -Name $name `
                -GetKeys { @(Get-ChildItem -LiteralPath $WorkerLxssKey) | ForEach-Object { $_.PSPath } } `
                -GetName {
                    param($key)
                    $item = Get-ItemProperty -LiteralPath $key -Name DistributionName -ErrorAction SilentlyContinue
                    if ($null -eq $item) { return $null }
                    return $item.DistributionName
                }
        } `
        -UnregisterDistribution {
            param($name)
            & $wslPath --unregister $name
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to unregister WSL distribution '$name'."
            }
        } `
        -RenameDistribution { param($key, $name) Set-ItemProperty -LiteralPath $key -Name DistributionName -Value $name } `
        -RestoreDistribution { param($name) & $assets.Paths["keepalive.ps1"] -DistroName $name } `
        -Finalize {
            param($name)
            & $assets.Paths["keepalive.ps1"] -DistroName $name
            & $assets.Paths["firewall.ps1"] -RemoteAddresses $configuration.RemoteAddresses
            Invoke-WorkerOverlay -WslPath $wslPath -Distro $name -Command @("enable")
            Invoke-WorkerOverlay -WslPath $wslPath -Distro $name -Command @("status")
        }

    Remove-WorkerStateArchive -Directory $root -Keep $statePath
    Write-Host "Worker '$distro' now runs $target. Agent state archive kept at $statePath."
}
