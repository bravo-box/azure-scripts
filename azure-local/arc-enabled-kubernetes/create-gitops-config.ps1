#Requires -Version 7.0
<#!
.SYNOPSIS
Creates a Flux v2 GitOps configuration on an Azure Arc-enabled Kubernetes cluster.

.DESCRIPTION
PowerShell equivalent of create-gitops-config.sh.

Features:
- Checks prerequisites (az, kubectl)
- Ensures connectedk8s, k8s-configuration, and k8s-extension Azure CLI extensions are installed
- Prompts for cloud selection/login when not authenticated
- Supports interactive cluster selection when -ClusterName is omitted
- Derives resource group and subscription from selected cluster
- Installs the Microsoft.Flux cluster extension if not already present
- Prompts for any GitOps settings not supplied as parameters, then asks for confirmation
- Creates the Flux configuration with `az k8s-configuration flux create` and shows its status
- Writes a timestamped log file in the script directory

.PARAMETER ClusterName
Optional Arc-enabled cluster name. If omitted, you can select from a list.

.PARAMETER RepoUrl
Git repository URL (https:// or ssh://).

.PARAMETER Branch
Git branch to sync. Default: main

.PARAMETER Path
Path within the repo to sync. Default / blank is the repo root.

.PARAMETER ConfigName
Flux configuration name. Default: cluster-config

.PARAMETER Namespace
Namespace for the Flux configuration. Default: flux-system

.PARAMETER Scope
Configuration scope: cluster or namespace. Default: namespace

.PARAMETER KustomizationName
Kustomization name. Default: apps

.PARAMETER SyncInterval
Sync interval, e.g. 1m, 5m. Default: 10m

.PARAMETER RetryInterval
Retry interval, e.g. 1m, 5m. Default: 10m

.PARAMETER Prune
Prune resources removed from Git: true or false. Default: true

.PARAMETER AuthType
Repository auth type: none, https, or ssh. Default: none

.PARAMETER HttpsUser
Username for HTTPS auth.

.PARAMETER HttpsToken
Password/PAT for HTTPS auth.

.PARAMETER SshKeyFile
Path to SSH private key file for SSH auth.

.PARAMETER KnownHostsFile
Path to known_hosts file for SSH auth.

.EXAMPLE
./create-gitops-config.ps1

.EXAMPLE
./create-gitops-config.ps1 -ClusterName myCluster -RepoUrl https://github.com/org/repo -Branch main -Path ./clusters/prod
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$RepoUrl,

    [Parameter(Mandatory = $false)]
    [string]$Branch = 'main',

    [Parameter(Mandatory = $false)]
    [string]$Path = '',

    [Parameter(Mandatory = $false)]
    [string]$ConfigName = 'cluster-config',

    [Parameter(Mandatory = $false)]
    [string]$Namespace = 'flux-system',

    [Parameter(Mandatory = $false)]
    [ValidateSet('cluster', 'namespace')]
    [string]$Scope = 'namespace',

    [Parameter(Mandatory = $false)]
    [string]$KustomizationName = 'apps',

    [Parameter(Mandatory = $false)]
    [string]$SyncInterval = '10m',

    [Parameter(Mandatory = $false)]
    [string]$RetryInterval = '10m',

    [Parameter(Mandatory = $false)]
    [ValidateSet('true', 'false')]
    [string]$Prune = 'true',

    [Parameter(Mandatory = $false)]
    [ValidateSet('none', 'https', 'ssh')]
    [string]$AuthType = 'none',

    [Parameter(Mandatory = $false)]
    [string]$HttpsUser,

    [Parameter(Mandatory = $false)]
    [string]$HttpsToken,

    [Parameter(Mandatory = $false)]
    [string]$SshKeyFile,

    [Parameter(Mandatory = $false)]
    [string]$KnownHostsFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptDir ("create-gitops-config_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

$script:ResourceGroup = ''
$script:Subscription = ''

$script:RepoUrl = $RepoUrl
$script:Branch = $Branch
$script:Path = $Path
$script:ConfigName = $ConfigName
$script:Namespace = $Namespace
$script:Scope = $Scope
$script:KustomizationName = $KustomizationName
$script:SyncInterval = $SyncInterval
$script:RetryInterval = $RetryInterval
$script:Prune = $Prune
$script:AuthType = $AuthType
$script:HttpsUser = $HttpsUser
$script:HttpsToken = $HttpsToken
$script:SshKeyFile = $SshKeyFile
$script:KnownHostsFile = $KnownHostsFile

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$Level] $Message"

    $color = switch ($Level) {
        'INFO' { 'Cyan' }
        'SUCCESS' { 'Green' }
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'White' }
    }

    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value "[$timestamp] $line"
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Ensure-CliExtension {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Log "Checking Azure CLI extension '$Name'..." 'INFO'

    $null = & az extension show --name $Name --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Installing Azure CLI extension '$Name'..." 'INFO'
        & az extension add --name $Name --upgrade --yes
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install Azure CLI extension '$Name'."
        }
    }

    Write-Log "$Name extension available." 'SUCCESS'
}

function Ensure-AzureLogin {
    Write-Log "Checking Azure authentication..." 'INFO'

    $accountJson = & az account show -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $accountJson) {
        $account = $accountJson | ConvertFrom-Json
        Write-Log "Authenticated. Current subscription: $($account.name)" 'SUCCESS'
        return
    }

    Write-Log "No active Azure login detected." 'WARN'
    Write-Host "Select cloud environment:"
    Write-Host "  1) AzureCloud"
    Write-Host "  2) AzureUSGovernment"

    while ($true) {
        $choice = Read-Host "Select cloud environment (1-2)"
        switch ($choice) {
            '1' {
                & az cloud set --name AzureCloud | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Failed to set cloud AzureCloud.' }
                Write-Log "Set cloud to AzureCloud." 'SUCCESS'
                break
            }
            '2' {
                & az cloud set --name AzureUSGovernment | Out-Null
                if ($LASTEXITCODE -ne 0) { throw 'Failed to set cloud AzureUSGovernment.' }
                Write-Log "Set cloud to AzureUSGovernment." 'SUCCESS'
                break
            }
            default {
                Write-Log "Invalid selection. Enter 1 or 2." 'WARN'
            }
        }
    }

    Write-Log "Starting Azure device-code login..." 'INFO'
    & az login --use-device-code | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure login failed.'
    }

    $postLoginAccount = (& az account show -o json | ConvertFrom-Json)
    Write-Log "Authenticated. Current subscription: $($postLoginAccount.name)" 'SUCCESS'
}

function Get-ArcClusters {
    Write-Log "Fetching Arc-enabled clusters..." 'INFO'

    $clustersJson = & az connectedk8s list --query "[].{name:name, resourceGroup:resourceGroup, id:id}" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $clustersJson) {
        return @()
    }

    $clusters = $clustersJson | ConvertFrom-Json
    if ($null -eq $clusters) {
        return @()
    }

    return @($clusters)
}

function Select-Cluster {
    param([Parameter(Mandatory = $true)][array]$Clusters)

    if ($Clusters.Count -eq 1) {
        Write-Log "Auto-selected cluster: $($Clusters[0].name)" 'SUCCESS'
        return $Clusters[0]
    }

    Write-Host ""
    Write-Host "Available Arc-enabled clusters:" -ForegroundColor Cyan
    Write-Host ("{0,-4} {1,-35} {2}" -f '#', 'Name', 'Resource Group') -ForegroundColor Cyan
    Write-Host ("-" * 80) -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Clusters.Count; $i++) {
        $c = $Clusters[$i]
        Write-Host ("{0,-4} {1,-35} {2}" -f ($i + 1), $c.name, $c.resourceGroup)
    }

    while ($true) {
        $selection = Read-Host "Select cluster (1-$($Clusters.Count))"
        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $Clusters.Count) {
            $cluster = $Clusters[$selectedIndex - 1]
            Write-Log "Selected cluster: $($cluster.name)" 'SUCCESS'
            return $cluster
        }

        Write-Log "Invalid selection. Enter a number between 1 and $($Clusters.Count)." 'WARN'
    }
}

function Initialize-ClusterContext {
    param([Parameter(Mandatory = $true)][pscustomobject]$Cluster)

    $script:ResourceGroup = [string]$Cluster.resourceGroup
    $clusterId = [string]$Cluster.id
    $idParts = $clusterId -split '/'

    if ($idParts.Count -lt 3 -or -not $idParts[2]) {
        throw "Unable to parse subscription from cluster ID: $clusterId"
    }

    $script:Subscription = $idParts[2]

    Write-Log "Cluster: $($Cluster.name)" 'SUCCESS'
    Write-Log "Resource Group: $script:ResourceGroup" 'SUCCESS'
    Write-Log "Subscription: $script:Subscription" 'SUCCESS'
}

function Read-GitOpsSettings {
    Write-Log "Collecting GitOps configuration settings..." 'INFO'
    Write-Host ""

    while (-not $script:RepoUrl) {
        $script:RepoUrl = Read-Host "Git repository URL (https:// or ssh://)"
    }

    $value = Read-Host "Branch to sync [$script:Branch]"
    if ($value) { $script:Branch = $value }

    $value = Read-Host "Path within repo to sync [$script:Path]"
    if ($value) { $script:Path = $value }

    $value = Read-Host "Flux configuration name [$script:ConfigName]"
    if ($value) { $script:ConfigName = $value }

    $value = Read-Host "Namespace for configuration [$script:Namespace]"
    if ($value) { $script:Namespace = $value }

    while ($true) {
        $value = Read-Host "Scope, cluster or namespace [$script:Scope]"
        if (-not $value) { $value = $script:Scope }
        if ($value -eq 'cluster' -or $value -eq 'namespace') {
            $script:Scope = $value
            break
        }
        Write-Log "Scope must be 'cluster' or 'namespace'" 'WARN'
    }

    $value = Read-Host "Kustomization name [$script:KustomizationName]"
    if ($value) { $script:KustomizationName = $value }

    $value = Read-Host "Sync interval [$script:SyncInterval]"
    if ($value) { $script:SyncInterval = $value }

    $value = Read-Host "Retry interval [$script:RetryInterval]"
    if ($value) { $script:RetryInterval = $value }

    while ($true) {
        $value = Read-Host "Prune resources removed from Git, true or false [$script:Prune]"
        if (-not $value) { $value = $script:Prune }
        if ($value -eq 'true' -or $value -eq 'false') {
            $script:Prune = $value
            break
        }
        Write-Log "Prune must be 'true' or 'false'" 'WARN'
    }

    Write-Host ""
    Write-Log "Select repository authentication method:" 'INFO'
    Write-Host "  1) None (public repository)"
    Write-Host "  2) HTTPS (username + password/PAT)"
    Write-Host "  3) SSH (private key)"
    Write-Host ""

    while ($true) {
        $authChoice = Read-Host "Select authentication method (1-3)"
        switch ($authChoice) {
            '1' { $script:AuthType = 'none'; break }
            '2' {
                $script:AuthType = 'https'
                $script:HttpsUser = Read-Host "HTTPS username"
                $secureToken = Read-Host "HTTPS password or PAT" -AsSecureString
                $script:HttpsToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken))
                break
            }
            '3' {
                $script:AuthType = 'ssh'
                while (-not $script:SshKeyFile -or -not (Test-Path $script:SshKeyFile)) {
                    $script:SshKeyFile = Read-Host "Path to SSH private key file"
                    if (-not (Test-Path $script:SshKeyFile)) {
                        Write-Log "File not found: $script:SshKeyFile" 'WARN'
                    }
                }
                $script:KnownHostsFile = Read-Host "Path to known_hosts file (optional, press enter to skip)"
                break
            }
            default {
                Write-Log "Invalid selection. Please enter 1, 2, or 3" 'WARN'
                continue
            }
        }
        break
    }
}

function Confirm-Configuration {
    $authSummary = 'None'
    switch ($script:AuthType) {
        'https' { $authSummary = "HTTPS (user: $script:HttpsUser, token: ****)" }
        'ssh' {
            $authSummary = "SSH (key: $script:SshKeyFile"
            if ($script:KnownHostsFile) { $authSummary += ", known_hosts: $script:KnownHostsFile" }
            $authSummary += ")"
        }
    }

    Write-Host ""
    Write-Log "Review GitOps configuration:" 'INFO'
    Write-Host "  Cluster:              $ClusterName"
    Write-Host "  Resource Group:       $script:ResourceGroup"
    Write-Host "  Subscription:         $script:Subscription"
    Write-Host "  Repository URL:       $script:RepoUrl"
    Write-Host "  Branch:               $script:Branch"
    Write-Host "  Path:                 $script:Path"
    Write-Host "  Configuration Name:   $script:ConfigName"
    Write-Host "  Namespace:            $script:Namespace"
    Write-Host "  Scope:                $script:Scope"
    Write-Host "  Kustomization Name:   $script:KustomizationName"
    Write-Host "  Sync Interval:        $script:SyncInterval"
    Write-Host "  Retry Interval:       $script:RetryInterval"
    Write-Host "  Prune:                $script:Prune"
    Write-Host "  Authentication:       $authSummary"
    Write-Host ""

    while ($true) {
        $confirm = Read-Host "Proceed with this configuration? (y/n)"
        switch ($confirm) {
            { $_ -in @('y', 'Y') } { return $true }
            { $_ -in @('n', 'N') } { return $false }
            default { Write-Log "Please enter 'y' or 'n'" 'WARN' }
        }
    }
}

function Ensure-FluxExtension {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Log "Checking for the Microsoft.Flux cluster extension..." 'INFO'

    $extensionsJson = & az k8s-extension list --cluster-name $Name --resource-group $script:ResourceGroup `
        --cluster-type connectedClusters -o json 2>$null

    $existing = $null
    if ($LASTEXITCODE -eq 0 -and $extensionsJson) {
        $extensions = $extensionsJson | ConvertFrom-Json
        $existing = $extensions | Where-Object { $_.extensionType -eq 'microsoft.flux' } | Select-Object -First 1
    }

    if ($existing) {
        Write-Log "Microsoft.Flux extension already installed on cluster" 'SUCCESS'
        return
    }

    Write-Log "Installing Microsoft.Flux extension on cluster (this can take a few minutes)..." 'INFO'
    & az k8s-extension create `
        --cluster-name $Name `
        --resource-group $script:ResourceGroup `
        --cluster-type connectedClusters `
        --extension-type microsoft.flux `
        --name flux
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install the Microsoft.Flux extension."
    }

    Write-Log "Microsoft.Flux extension installed" 'SUCCESS'
}

function New-FluxConfiguration {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Log "Creating Flux GitOps configuration '$script:ConfigName'..." 'INFO'

    $argsList = @(
        'k8s-configuration', 'flux', 'create',
        '--cluster-name', $Name,
        '--resource-group', $script:ResourceGroup,
        '--cluster-type', 'connectedClusters',
        '--name', $script:ConfigName,
        '--namespace', $script:Namespace,
        '--url', $script:RepoUrl,
        '--branch', $script:Branch,
        '--scope', $script:Scope,
        '--kustomization',
        "name=$script:KustomizationName",
        "path=$script:Path",
        "prune=$script:Prune",
        "sync_interval=$script:SyncInterval",
        "retry_interval=$script:RetryInterval"
    )

    switch ($script:AuthType) {
        'https' {
            $argsList += @('--https-user', $script:HttpsUser, '--https-key', $script:HttpsToken)
        }
        'ssh' {
            $argsList += @('--ssh-private-key-file', $script:SshKeyFile)
            if ($script:KnownHostsFile) {
                $argsList += @('--known-hosts-contents-file', $script:KnownHostsFile)
            }
        }
    }

    & az @argsList
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create Flux configuration '$script:ConfigName'."
    }

    Write-Log "Flux GitOps configuration '$script:ConfigName' created" 'SUCCESS'
}

function Get-ConfigurationStatus {
    param([Parameter(Mandatory = $true)][string]$Name)

    Write-Log "Fetching configuration status..." 'INFO'
    & az k8s-configuration flux show `
        --cluster-name $Name `
        --resource-group $script:ResourceGroup `
        --cluster-type connectedClusters `
        --name $script:ConfigName `
        -o table

    Write-Log "To check Flux resources on the cluster directly, run:" 'INFO'
    Write-Log "  kubectl get gitrepositories,kustomizations -n $script:Namespace" 'INFO'
}

try {
    Write-Log "Azure Arc Kubernetes Flux GitOps Configuration Script (PowerShell)" 'INFO'
    Write-Log "===================================================================" 'INFO'
    Write-Log "Log file: $LogFile" 'INFO'

    Assert-Command -Name 'az'
    Write-Log "Azure CLI found." 'SUCCESS'

    Assert-Command -Name 'kubectl'
    Write-Log "kubectl found." 'SUCCESS'

    Ensure-CliExtension -Name 'connectedk8s'
    Ensure-CliExtension -Name 'k8s-configuration'
    Ensure-CliExtension -Name 'k8s-extension'
    Ensure-AzureLogin

    $clusters = Get-ArcClusters
    if ($clusters.Count -eq 0) {
        throw 'No Arc-enabled clusters found in accessible subscriptions.'
    }

    $selectedCluster = $null
    if ($ClusterName) {
        $selectedCluster = @($clusters | Where-Object { $_.name -eq $ClusterName }) | Select-Object -First 1
        if (-not $selectedCluster) {
            throw "Cluster '$ClusterName' not found. Run without -ClusterName to select interactively."
        }
        Write-Log "Using provided cluster name: $ClusterName" 'SUCCESS'
    }
    else {
        $selectedCluster = Select-Cluster -Clusters $clusters
    }

    $ClusterName = [string]$selectedCluster.name
    Initialize-ClusterContext -Cluster $selectedCluster

    do {
        Read-GitOpsSettings
        $confirmed = Confirm-Configuration
        if (-not $confirmed) {
            Write-Log "Let's re-enter the configuration." 'WARN'
        }
    } while (-not $confirmed)

    Ensure-FluxExtension -Name $ClusterName
    New-FluxConfiguration -Name $ClusterName
    Get-ConfigurationStatus -Name $ClusterName
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
