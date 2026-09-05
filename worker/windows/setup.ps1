[CmdletBinding()]
param(
    [string]$Config,
    [string]$Release,
    [System.Security.SecureString]$VaultPassword,
    [switch]$Replace
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

if ($MyInvocation.InvocationName -ne ".") {
    Assert-WorkerElevated | Out-Null

    $configPath = Get-WorkerConfigPath -Path $Config
    $configuration = Read-WorkerConfig -Path $configPath
    $architecture = if ([string]::IsNullOrWhiteSpace($configuration.Architecture)) { Get-WorkerArchitecture } else { $configuration.Architecture }
    $wslPath = Get-WorkerWslPath
    $download = { param($uri, $path) Invoke-WebRequest -Uri $uri -OutFile $path -UseBasicParsing }

    $tag = if (-not [string]::IsNullOrWhiteSpace($Release)) { $Release } else { $configuration.Release }
    if ($tag -ceq "latest") {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$($configuration.Repository)/releases?per_page=50" -UseBasicParsing
        $tag = Select-WorkerReleaseTag -Releases @($releases)
    }

    $registered = & $wslPath --list --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list installed WSL distributions."
    }
    if (Test-WorkerDistributionRegistered -Output $registered -Name $configuration.Distro) {
        if (-not $Replace) {
            throw "WSL distribution '$($configuration.Distro)' already exists. Run update.ps1, or pass -Replace to rebuild it from '$tag'."
        }
        $updateParameters = @{ Config = $configPath; Release = $tag; Force = $true }
        if ($PSBoundParameters.ContainsKey("VaultPassword")) {
            $updateParameters["VaultPassword"] = $VaultPassword
        }
        & (Join-Path $PSScriptRoot "update.ps1") @updateParameters
        return
    }

    $credentialPath = Get-WorkerCredentialPath
    $credentialParameters = @{ Path = $credentialPath }
    if ($PSBoundParameters.ContainsKey("VaultPassword")) {
        $credentialParameters["VaultPassword"] = $VaultPassword
    }
    $credential = Get-WorkerVaultCredential @credentialParameters

    $stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) "openhands-worker\$tag"
    $assets = Get-WorkerReleaseAssets -Configuration $configuration -Tag $tag -Architecture $architecture `
        -Directory $stagingDirectory -Download $download
    $profilePath = Resolve-WorkerProfilePath -ProfileAsset $configuration.Profile -Directory $stagingDirectory -Download $download
    Write-Host "Verified $($assets.Paths.Count) release assets of $tag against checksums.txt."

    & $assets.Paths["install.ps1"] -DistroName $configuration.Distro -ImagePath $assets.Image -ImageSha256 $assets.ImageHash
    & $assets.Paths["firewall.ps1"] -RemoteAddresses $configuration.RemoteAddresses
    & $assets.Paths["keepalive.ps1"] -DistroName $configuration.Distro

    $overlay = {
        param($command, $usePassword, $inputPath)
        $parameters = @{ WslPath = $wslPath; Distro = $configuration.Distro; Command = $command }
        if ($usePassword) { $parameters["Credential"] = $credential }
        if ($inputPath) { $parameters["InputPath"] = $inputPath }
        Invoke-WorkerOverlay @parameters
    }
    Invoke-WorkerProvision -Configuration $configuration -OverlayPath $assets.Paths["openhands-overlay"] `
        -ProfilePath $profilePath -CommonProfilePath $assets.CommonProfile -StatePath $null `
        -CopyFile { param($source, $destination, $mode) Copy-WorkerFileToDistribution -WslPath $wslPath -Distro $configuration.Distro -Path $source -Destination $destination -Mode $mode } `
        -Overlay $overlay
    Invoke-WorkerActivation -Overlay $overlay -ProfilePaths (Get-WorkerGuestProfilePaths -CommonProfilePath $assets.CommonProfile)

    Invoke-WorkerOverlay -WslPath $wslPath -Distro $configuration.Distro -Command @("status")
    Write-Host "Worker '$($configuration.Distro)' is installed from $tag and reachable from $($configuration.RemoteAddresses -join ', ')."
    Write-Host "Vault master password stored DPAPI-protected at $credentialPath."
}
