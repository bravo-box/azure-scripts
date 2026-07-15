# This PowerShell script is designed to set up prerequisites for deploying Azure Local clusters.
# It connects to the appropriate Azure environment, retrieves necessary context information,
# checks and registers required resource providers, and invokes the Azure Stack HCI Arc initialization.

# Notice, ensure that the Resource Providers are registered
# Check if Resource Providers are registered
$providers = @("Microsoft.HybridCompute", "Microsoft.GuestConfiguration", "Microsoft.HybridConnectivity", "Microsoft.AzureStackHCI", "Microsoft.Kubernetes", "Microsoft.KubernetesConfiguration", "Microsoft.ExtendedLocation", "Microsoft.ResourceConnector", "Microsoft.HybridContainerService", "Microsoft.Attestation")

Write-Host "Before proceeding ensure the following Resource Providers are registered in your subscription:"
$providers | ForEach-Object { Write-Host "- $_" }

$RPConfirmed = Read-Host -Prompt "Confirm you have registered the required Resource Providers on your subscription? (y/n)"
switch ($RPConfirmed) {
    "y" {
        Write-Host "Proceeding with the registration."
    }
    "n" {
        Write-Host "Canceling... Please register the required Resource Providers on the subscription and run the script again."
        exit
    }
    Default {
        Write-Host "Invalid selection. Please run the script again and select a valid option."
        exit
    }
}

# Enter the number for your Azure environment, Commercial(1), USGov(2)
$envChoice = Read-Host -Prompt "Select your Azure Environment: Commercial(1), USGov(2)"

# Prompt for user-assigned managed identity details
$identityResourceGroup = Read-Host -Prompt "Enter the Resource Group Name for the user-assigned managed identity"
$identityName = Read-Host -Prompt "Enter the Name of the user-assigned managed identity"

# Optional: attach the managed identity to a VM before authenticating with it
$assignIdentityToVm = Read-Host -Prompt "Assign this user-assigned identity to a VM now? (y/n)"
if ($assignIdentityToVm -eq "y") {
    $vmResourceGroup = Read-Host -Prompt "Enter VM Resource Group Name"
    $vmName = Read-Host -Prompt "Enter VM Name"
}

switch ($envChoice) {
    "1" {
        $Region = "eastus"
        $Cloud = "AzureCloud"
        $EnvironmentName = "AzureCloud"
    }
    "2" {
        $Region = "usgovvirginia"
        $Cloud = "AzureUSGovernment"
        $EnvironmentName = "AzureUSGovernment"
    }
    Default {
        Write-Host "Invalid selection. Please run the script again and select a valid option."
        exit
    }
}

# Sign in with managed identity to query the user-assigned identity object.
Connect-AzAccount -Environment $EnvironmentName -Identity | Out-Null

# Retrieve user-assigned managed identity details.
$identity = Get-AzUserAssignedIdentity -ResourceGroupName $identityResourceGroup -Name $identityName

# Optionally attach user-assigned identity to the target VM.
if ($assignIdentityToVm -eq "y") {
    Get-AzVM -ResourceGroupName $vmResourceGroup -Name $vmName | Update-AzVM -IdentityType UserAssigned -IdentityId $identity.Id | Out-Null
    Write-Host "Assigned user-assigned identity '$identityName' to VM '$vmName'."
}

# Re-authenticate using the user-assigned managed identity client ID.
Connect-AzAccount -Environment $EnvironmentName -Identity -AccountId $identity.ClientId | Out-Null

# Removed redundant Connect-AzAccount and $Region assignment since it's handled in the switch statement
# Get Tenant ID and Context
$tenantId = (Get-AzContext).Tenant.Id
Write-Host "Current Tenant ID: $tenantId"

# Get Subscription ID and Context
$subscriptionId = (Get-AzContext).Subscription.Id
Write-Host "Current Subscription ID: $subscriptionId"

#Get the Account ID for the registration
$id = (Get-AzContext).Account.Id

# Prompt for Resource Group Name
$RG = Read-Host -Prompt "Enter the Resource Group Name for your Azure Local cluster nodes"

#Define the proxy address if your Azure Local deployment accesses the internet via proxy
#$ProxyServer = "http://proxyaddress:port"

# Get Access Token
$armTokenResponse = Get-AzAccessToken

# Convert token to string for use in initialization
# Required because Get-AzAccessToken returns SecureString
$armAccessTokenPlain = [System.Net.NetworkCredential]::new("", $armTokenResponse.Token).Password

#Invoke the registration script. Use a supported region.
Invoke-AzStackHciArcInitialization -SubscriptionID $subscriptionId -ResourceGroup $RG -TenantID $tenantId -Region $Region -Cloud $Cloud -ArmAccessToken $armAccessTokenPlain -AccountID $id
