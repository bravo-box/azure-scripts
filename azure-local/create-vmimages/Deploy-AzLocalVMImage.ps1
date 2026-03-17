#Requires -Module Az.Resources
<#
.SYNOPSIS
Deploys one or more Azure Local VM gallery images from an Azure Storage Account.

.DESCRIPTION
Collects deployment parameters, resolves optional values automatically, and deploys
Azure Local gallery images using the bundled ARM template. When -ImageBlobName is
omitted the script lists all blobs in the container and lets you choose one or more
interactively (comma-separated numbers, ranges such as 1-3, or * for all). Each
selected blob is deployed as a separate gallery image. A per-image SAS token is
generated for each blob and a summary table is printed at the end.
Ensure that parameters ContainerName, OSType, HyperVGeneration are set correctly before running the script.

.PARAMETER ResourceGroupName
The resource group where the gallery image will be deployed.

.PARAMETER CustomLocationId
The resource ID of the Azure Local custom location. If omitted, the script queries
the subscription for all available custom locations and prompts you to select one.

.PARAMETER ImageName
Override name for the gallery image. Only applies when -ImageBlobName is also
supplied (single-image mode). Omit to have the name derived from the blob filename.

.PARAMETER StorageAccountName
Name of the Azure Storage Account containing the VM image blob.

.PARAMETER StorageAccountResourceGroup
Resource group containing the source storage account. If omitted, the script queries
Azure to locate it by storage account name within the current subscription.

.PARAMETER StorageAccountSubscription
Subscription ID containing the source storage account. If omitted, the script resolves
it from the storage account resource lookup in the current subscription.

.PARAMETER ContainerName
Blob container name in the storage account (default: vmimages).

.PARAMETER ImageBlobName
Name of the image blob file in the storage account (e.g., Windows2022.vhd). If omitted, the
script lists all blobs in the container and lets you choose one or more interactively.

.PARAMETER ImageNamePrefix
Optional prefix to prepend to image names derived from blob filenames during multi-select.
For example, a prefix of "prod-" turns "Windows2022.vhd" into "prod-windows2022".

.PARAMETER OsType
Operating system type applied to all selected images: Windows or Linux (default: Windows).

.PARAMETER HyperVGeneration
Hyper-V generation: V1 or V2 (default: V2).

.PARAMETER ImageVersion
Version label for the image (default: 1.0.0).

.PARAMETER Location
Azure region for the gallery image. Defaults to the resource group location when omitted.

.PARAMETER TemplatePath
Path to the ARM template file (default: ./deploy_azl_vmimages.json).

.PARAMETER DeploymentName
Name for the ARM deployment (default: azl-vmimage-{timestamp}).

.PARAMETER ValidateOnly
Only validate the generated parameters and template without deploying.

.PARAMETER WhatIf
Preview the deployment without executing it.

.EXAMPLE
# Deploy a single image by name (storage details auto-resolved, custom location interactive)
.\Deploy-AzLocalVMImage.ps1 `
  -ResourceGroupName "my-azurelocal-rg" `
  -ImageName "windows-server-2022" `
  -StorageAccountName "myimagestore" `
  -ImageBlobName "Windows2022.vhd"

.EXAMPLE
# Interactive multi-select: list all blobs in container and choose which to deploy
.\Deploy-AzLocalVMImage.ps1 `
    -ResourceGroupName "my-azurelocal-rg" `
    -StorageAccountName "myimagestore" `
    -ImageNamePrefix "prod-"
# Prompts for custom location, then lists blobs and asks which to deploy.
# Blob "Windows2022.vhdx" becomes image "prod-windows2022".

.EXAMPLE
# Deploy all blobs in the container without prompting (-ImageBlobName omitted, * selected automatically via pipeline)
# Use ValidateOnly first to confirm names before real deployment
.\Deploy-AzLocalVMImage.ps1 `
  -ResourceGroupName "my-azurelocal-rg" `
  -CustomLocationId "/subscriptions/.../customlocations/my-loc" `
  -StorageAccountName "myimagestore" `
  -StorageAccountResourceGroup "storage-rg" `
  -StorageAccountSubscription "12345678-abcd-1234-abcd-123456789012" `
    -OsType "Linux" `
    -ValidateOnly
# (type * at the blob selection prompt to select all)

.EXAMPLE
# Preview a deployment (WhatIf)
.\Deploy-AzLocalVMImage.ps1 `
  -ResourceGroupName "my-azurelocal-rg" `
  -CustomLocationId "/subscriptions/.../customlocations/my-loc" `
  -ImageName "windows-server-2022" `
  -StorageAccountName "myimagestore" `
  -StorageAccountResourceGroup "storage-rg" `
  -StorageAccountSubscription "12345678-abcd-1234-abcd-123456789012" `
  -ImageBlobName "Windows2022.vhd" `
  -WhatIf
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$CustomLocationId = "",

    [Parameter(Mandatory = $false)]
    [string]$ImageName = "",

    [Parameter(Mandatory = $true)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountResourceGroup = "",

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountSubscription = "",

    [Parameter(Mandatory = $false)]
    [string]$ImageBlobName = "",

    [Parameter(Mandatory = $false)]
    [string]$ImageNamePrefix = "",

    [Parameter(Mandatory = $false)]
    [string]$ContainerName = "vmimages",

    [Parameter(Mandatory = $false)]
    [ValidateSet("Windows", "Linux")]
    [string]$OsType = "Windows",

    [Parameter(Mandatory = $false)]
    [ValidateSet("V1", "V2")]
    [string]$HyperVGeneration = "V2",

    [Parameter(Mandatory = $false)]
    [string]$ImageVersion = "1.0.0",

    [Parameter(Mandatory = $false)]
    [string]$Location = "",

    [Parameter(Mandatory = $false)]
    [string]$TemplatePath = "$PSScriptRoot/deploy_azl_vmimages.json",

    [Parameter(Mandatory = $false)]
    [string]$DeploymentName = "azl-vmimage-$(Get-Date -Format 'yyyyMMddHHmmss')",

    [Parameter(Mandatory = $false)]
    [switch]$ValidateOnly,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ValidationErrorDetails {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ErrorObject,

        [Parameter(Mandatory = $false)]
        [string]$Indent = "  "
    )

    if ($null -eq $ErrorObject) {
        return
    }

    $items = @($ErrorObject)
    foreach ($item in $items) {
        $message = $null
        $code = $null
        $target = $null

        if ($item.PSObject.Properties['Message']) {
            $message = $item.Message
        }
        elseif ($item.PSObject.Properties['Exception'] -and $item.Exception) {
            $message = $item.Exception.Message
        }
        else {
            $message = [string]$item
        }

        if ($item.PSObject.Properties['Code']) {
            $code = $item.Code
        }

        if ($item.PSObject.Properties['Target']) {
            $target = $item.Target
        }

        if ($code) {
            Write-Host "$Indent Code   : $code" -ForegroundColor Red
        }
        if ($target) {
            Write-Host "$Indent Target : $target" -ForegroundColor Red
        }
        if ($message) {
            Write-Host "$Indent Message: $message" -ForegroundColor Red
        }

        if ($item.PSObject.Properties['Details'] -and $item.Details) {
            Write-ValidationErrorDetails -ErrorObject $item.Details -Indent ("$Indent  ")
        }
    }
}

Write-Host "================================" -ForegroundColor Cyan
Write-Host "Azure Local VM Image Deployment" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Validate template file exists
if (-not (Test-Path $TemplatePath)) {
    throw "Template file not found: $TemplatePath"
}

# Resolve subscription ID from current Az context
$azContext = Get-AzContext
if (-not $azContext -or -not $azContext.Subscription) {
    throw "No active Azure login context found. Run 'Connect-AzAccount' before executing this script."
}
$SubscriptionId = $azContext.Subscription.Id
Write-Host "Resolved subscription   : $($azContext.Subscription.Name) ($SubscriptionId)" -ForegroundColor Green

# Resolve CustomLocationId interactively if not supplied
if (-not $CustomLocationId) {
    Write-Host "CustomLocationId not provided — querying subscription for custom locations..." -ForegroundColor Yellow
    $customLocations = @(Get-AzResource `
        -ResourceType "Microsoft.ExtendedLocation/customLocations" `
        -ErrorAction SilentlyContinue)

    if (-not $customLocations -or $customLocations.Count -eq 0) {
        throw "No custom locations found in subscription '$SubscriptionId'. Provide -CustomLocationId explicitly."
    }

    if ($customLocations.Count -eq 1) {
        $CustomLocationId = $customLocations[0].ResourceId
        Write-Host "Auto-selected custom location : $($customLocations[0].Name)" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "Available Custom Locations:" -ForegroundColor Cyan
        Write-Host ("{0,-4} {1,-35} {2,-25} {3}" -f "#", "Name", "Resource Group", "Location") -ForegroundColor Cyan
        Write-Host ("-" * 90) -ForegroundColor DarkGray
        for ($i = 0; $i -lt $customLocations.Count; $i++) {
            $cl = $customLocations[$i]
            Write-Host ("{0,-4} {1,-35} {2,-25} {3}" -f ($i + 1), $cl.Name, $cl.ResourceGroupName, $cl.Location)
        }
        Write-Host ""

        while ($true) {
            $selection = Read-Host "Select custom location by number (1-$($customLocations.Count))"
            $selectedIndex = 0
            if ([int]::TryParse($selection, [ref]$selectedIndex) -and
                $selectedIndex -ge 1 -and $selectedIndex -le $customLocations.Count) {
                $CustomLocationId = $customLocations[$selectedIndex - 1].ResourceId
                Write-Host "Selected : $($customLocations[$selectedIndex - 1].Name)" -ForegroundColor Green
                break
            }
            Write-Host "Invalid selection. Enter a number between 1 and $($customLocations.Count)." -ForegroundColor Yellow
        }
    }
    Write-Host ""
}
# Resolve storage account details (supports cross-resource-group and cross-subscription)
$storageLookupSubscription = if ($StorageAccountSubscription) { $StorageAccountSubscription } else { $SubscriptionId }
$originalContextSubscription = $SubscriptionId
$contextChanged = $false
$storageBlobEndpoint = $null
$imagePathSasUrl = $null

if ($storageLookupSubscription -ne $originalContextSubscription) {
    Write-Host "Switching context to storage subscription: $storageLookupSubscription" -ForegroundColor Yellow
    Set-AzContext -SubscriptionId $storageLookupSubscription | Out-Null
    $contextChanged = $true
}

try {
    if ($StorageAccountResourceGroup) {
        $storageResource = @(Get-AzResource `
            -ResourceType "Microsoft.Storage/storageAccounts" `
            -Name $StorageAccountName `
            -ResourceGroupName $StorageAccountResourceGroup `
            -ErrorAction SilentlyContinue)
    }
    else {
        Write-Host "StorageAccountResourceGroup not provided — querying Azure..." -ForegroundColor Yellow
        $storageResource = @(Get-AzResource `
            -ResourceType "Microsoft.Storage/storageAccounts" `
            -Name $StorageAccountName `
            -ErrorAction SilentlyContinue)
    }

    if ($storageResource.Count -eq 0) {
        if ($StorageAccountResourceGroup) {
            throw "Storage account '$StorageAccountName' was not found in resource group '$StorageAccountResourceGroup' under subscription '$storageLookupSubscription'."
        }
        throw "Storage account '$StorageAccountName' was not found in subscription '$storageLookupSubscription'. Provide -StorageAccountResourceGroup and/or -StorageAccountSubscription if the account is elsewhere."
    }

    if ($storageResource.Count -gt 1) {
        throw "Multiple storage accounts named '$StorageAccountName' were found. Provide -StorageAccountResourceGroup to disambiguate."
    }

    $StorageAccountResourceGroup = $storageResource[0].ResourceGroupName
    $StorageAccountSubscription = $storageResource[0].SubscriptionId

    # Resolve cloud-correct blob endpoint from Azure (works for public and sovereign clouds).
    $storageBlobEndpoint = az storage account show `
        -n $StorageAccountName `
        -g $StorageAccountResourceGroup `
        --subscription $StorageAccountSubscription `
        --query primaryEndpoints.blob `
        -o tsv 2>$null

    if (-not $storageBlobEndpoint) {
        throw "Unable to resolve blob endpoint for storage account '$StorageAccountName' in '$StorageAccountResourceGroup' / '$StorageAccountSubscription'. Ensure Azure CLI is installed, signed in, and you have read access."
    }

    if (-not $storageBlobEndpoint.EndsWith('/')) {
        $storageBlobEndpoint = "$storageBlobEndpoint/"
    }

    Write-Host "Resolved storage account RG           : $StorageAccountResourceGroup" -ForegroundColor Green
    Write-Host "Resolved storage account subscription : $StorageAccountSubscription" -ForegroundColor Green
    Write-Host "Resolved storage blob endpoint        : $storageBlobEndpoint" -ForegroundColor Green

    # If no specific blob was supplied, list container blobs and prompt for selection
    if (-not $ImageBlobName) {
        Write-Host "" 
        Write-Host "Listing blobs in container '$ContainerName'..." -ForegroundColor Yellow
        $blobListJson = az storage blob list `
            --account-name $StorageAccountName `
            --container-name $ContainerName `
            --auth-mode login `
            --subscription $StorageAccountSubscription `
            --query "[].name" `
            -o json 2>$null

        if (-not $blobListJson) {
            throw "Unable to list blobs in container '$ContainerName'. Verify the container exists and your identity has Storage Blob Data Reader access."
        }

        $allBlobs = $blobListJson | ConvertFrom-Json
        if (-not $allBlobs -or $allBlobs.Count -eq 0) {
            throw "No blobs found in container '$ContainerName' of storage account '$StorageAccountName'."
        }

        Write-Host ""
        Write-Host "Available blobs in '$ContainerName':" -ForegroundColor Cyan
        Write-Host ("{0,-4} {1}" -f "#", "Blob Name") -ForegroundColor Cyan
        Write-Host ("-" * 70) -ForegroundColor DarkGray
        for ($i = 0; $i -lt $allBlobs.Count; $i++) {
            Write-Host ("{0,-4} {1}" -f ($i + 1), $allBlobs[$i])
        }
        Write-Host ""
        Write-Host "Enter numbers separated by commas, a range (e.g. 1-3), or * for all:" -ForegroundColor Yellow
        $blobSelection = Read-Host "Selection"
        $blobSelection = $blobSelection.Trim()

        $selectedIndices = [System.Collections.Generic.List[int]]::new()
        if ($blobSelection -eq '*') {
            for ($i = 0; $i -lt $allBlobs.Count; $i++) { $selectedIndices.Add($i) }
        } else {
            foreach ($part in ($blobSelection -split ',')) {
                $part = $part.Trim()
                if ($part -match '^(\d+)-(\d+)$') {
                    $rangeStart = [int]$Matches[1] - 1
                    $rangeEnd   = [int]$Matches[2] - 1
                    if ($rangeStart -lt 0 -or $rangeEnd -ge $allBlobs.Count -or $rangeStart -gt $rangeEnd) {
                        throw "Invalid range '$part'. Valid numbers are 1-$($allBlobs.Count)."
                    }
                    for ($r = $rangeStart; $r -le $rangeEnd; $r++) { $selectedIndices.Add($r) }
                } elseif ($part -match '^\d+$') {
                    $idx = [int]$part - 1
                    if ($idx -lt 0 -or $idx -ge $allBlobs.Count) {
                        throw "Invalid selection '$part'. Valid numbers are 1-$($allBlobs.Count)."
                    }
                    $selectedIndices.Add($idx)
                } else {
                    throw "Unrecognised selection token '$part'. Use numbers, ranges (e.g. 1-3), or *."                    
                }
            }
        }

        $selectedIndices = @($selectedIndices | Select-Object -Unique | Sort-Object)
        if ($selectedIndices.Count -eq 0) {
            throw "No blobs selected. Exiting."
        }

        $script:selectedBlobEntries = $selectedIndices | ForEach-Object {
            $blobName  = $allBlobs[$_]
            $stem      = [System.IO.Path]::GetFileNameWithoutExtension($blobName).ToLower() -replace '[^a-z0-9-]', '-'
            $derivedImageName = "$ImageNamePrefix$stem"
            [PSCustomObject]@{ BlobName = $blobName; ImageName = $derivedImageName }
        }

        Write-Host ""
        Write-Host "Selected blobs and derived image names:" -ForegroundColor Cyan
        Write-Host ("{0,-4} {1,-45} {2}" -f "#", "Blob", "Image Name") -ForegroundColor Cyan
        Write-Host ("-" * 90) -ForegroundColor DarkGray
        $n = 1
        foreach ($entry in $script:selectedBlobEntries) {
            Write-Host ("{0,-4} {1,-45} {2}" -f $n, $entry.BlobName, $entry.ImageName)
            $n++
        }
        Write-Host ""
    } else {
        # Single blob / image name supplied via parameters
        $derivedName = if ($ImageName) { $ImageName } else {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($ImageBlobName).ToLower() -replace '[^a-z0-9-]', '-'
            "$ImageNamePrefix$stem"
        }
        $script:selectedBlobEntries = @([PSCustomObject]@{ BlobName = $ImageBlobName; ImageName = $derivedName })
    }
}
finally {
    if ($contextChanged) {
        Write-Host "Restoring context to deployment subscription: $originalContextSubscription" -ForegroundColor DarkGray
        Set-AzContext -SubscriptionId $originalContextSubscription | Out-Null
    }
}

# Common header displayed once before the per-image loop
Write-Host "Template       : $TemplatePath" -ForegroundColor Green
Write-Host "Subscription   : $SubscriptionId" -ForegroundColor Green
Write-Host "(subscription detected from Az context)" -ForegroundColor DarkGray
Write-Host "Resource Group : $ResourceGroupName" -ForegroundColor Green
Write-Host "Custom Location: $CustomLocationId" -ForegroundColor Green
Write-Host "Storage Account: $StorageAccountName ($ContainerName)" -ForegroundColor Green
Write-Host "OS / HyperV    : $OsType / $HyperVGeneration" -ForegroundColor Green
Write-Host "Images to deploy: $($script:selectedBlobEntries.Count)" -ForegroundColor Cyan
Write-Host ""

# Validate resource group once
Write-Host "Verifying resource group..." -ForegroundColor Yellow
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    throw "Resource group '$ResourceGroupName' not found in subscription '$SubscriptionId'"
}
Write-Host "Resource group found: $($rg.ResourceGroupName) (Location: $($rg.Location))" -ForegroundColor Green
Write-Host ""

$deployResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$generatedParamsPath = $null

try {
    $entryIndex = 0
    foreach ($blobEntry in $script:selectedBlobEntries) {
        $entryIndex++
        $currentBlobName = $blobEntry.BlobName
        $currentImageName = $blobEntry.ImageName
        $currentDeploymentName = "azl-vmimage-$(Get-Date -Format 'yyyyMMddHHmmss')-$entryIndex"

        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host "[$entryIndex/$($script:selectedBlobEntries.Count)] $currentImageName  <-  $currentBlobName" -ForegroundColor Cyan
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host ""

        Write-Host "  Verifying blob and generating SAS..." -ForegroundColor Yellow
        $blobExistsOutput = az storage blob show `
            --account-name $StorageAccountName `
            --container-name $ContainerName `
            --name $currentBlobName `
            --auth-mode login `
            --subscription $StorageAccountSubscription `
            --query "name" `
            -o tsv 2>$null

        if (-not $blobExistsOutput) {
            Write-Host "  SKIP: Blob '$currentBlobName' not found - skipping." -ForegroundColor Yellow
            $deployResults.Add([PSCustomObject]@{ ImageName = $currentImageName; BlobName = $currentBlobName; Status = "Skipped (blob not found)" })
            continue
        }

        $sasExpiryUtc = (Get-Date).ToUniversalTime().AddHours(4).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $sasToken = az storage blob generate-sas `
            --account-name $StorageAccountName `
            --container-name $ContainerName `
            --name $currentBlobName `
            --permissions r `
            --expiry $sasExpiryUtc `
            --https-only `
            --auth-mode login `
            --as-user `
            --subscription $StorageAccountSubscription `
            -o tsv 2>$null

        if (-not $sasToken) {
            throw "Unable to generate SAS token for blob '$currentBlobName'. Ensure your identity has Storage Blob Data Reader and Storage Blob Delegator roles."
        }

        if ($sasToken.StartsWith('?')) {
            $sasToken = $sasToken.Substring(1)
        }

        $blobPathEncoded = (($currentBlobName -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $imagePathSasUrl = "$storageBlobEndpoint$ContainerName/$blobPathEncoded`?$sasToken"
        Write-Host "  SAS generated: [secure value]" -ForegroundColor Green

        $generatedParamsPath = [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            "deploy_azl_vmimages_params_$(Get-Date -Format 'yyyyMMddHHmmss')_$entryIndex.json"
        )

        $parametersContent = [ordered]@{
            "`$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
            contentVersion = "1.0.0.0"
            parameters = [ordered]@{
                customLocationId = @{ value = $CustomLocationId }
                imageName = @{ value = $currentImageName }
                storageAccountName = @{ value = $StorageAccountName }
                storageAccountResourceGroup = @{ value = $StorageAccountResourceGroup }
                storageAccountSubscription = @{ value = $StorageAccountSubscription }
                imagePath = @{ value = $imagePathSasUrl }
                containerName = @{ value = $ContainerName }
                imageBlobName = @{ value = $currentBlobName }
                osType = @{ value = $OsType }
                hyperVGeneration = @{ value = $HyperVGeneration }
                imageVersion = @{ value = $ImageVersion }
            }
        }

        if ($Location) {
            $parametersContent.parameters.location = @{ value = $Location }
        }

        $parametersContent | ConvertTo-Json -Depth 5 | Set-Content -Path $generatedParamsPath -Encoding UTF8

        try {
            Write-Host "  Validating ARM template..." -ForegroundColor Yellow
            $validation = Test-AzResourceGroupDeployment `
                -ResourceGroupName $ResourceGroupName `
                -TemplateFile $TemplatePath `
                -TemplateParameterFile $generatedParamsPath

            if ($validation) {
                Write-Host "  Template validation errors:" -ForegroundColor Red
                Write-ValidationErrorDetails -ErrorObject $validation
                throw "Template validation failed for '$currentImageName'"
            }
            Write-Host "  Template validation passed" -ForegroundColor Green

            if ($ValidateOnly) {
                Write-Host "  [ValidateOnly] Skipping deploy for '$currentImageName'." -ForegroundColor Yellow
                $deployResults.Add([PSCustomObject]@{ ImageName = $currentImageName; BlobName = $currentBlobName; Status = "Validated (no deploy)" })
                continue
            }

            if ($WhatIf) {
                Write-Host "  [WhatIf] Previewing deployment for '$currentImageName'..." -ForegroundColor Yellow
                New-AzResourceGroupDeployment `
                    -ResourceGroupName $ResourceGroupName `
                    -TemplateFile $TemplatePath `
                    -TemplateParameterFile $generatedParamsPath `
                    -Name $currentDeploymentName `
                    -WhatIf
                $deployResults.Add([PSCustomObject]@{ ImageName = $currentImageName; BlobName = $currentBlobName; Status = "WhatIf preview shown" })
                continue
            }

            Write-Host "  Deploying '$currentImageName'... (this may take several minutes)" -ForegroundColor Yellow
            $deployment = New-AzResourceGroupDeployment `
                -ResourceGroupName $ResourceGroupName `
                -TemplateFile $TemplatePath `
                -TemplateParameterFile $generatedParamsPath `
                -Name $currentDeploymentName `
                -Verbose

            if ($deployment.ProvisioningState -eq "Succeeded") {
                Write-Host "  Deployment succeeded: $currentImageName" -ForegroundColor Green
                $deployResults.Add([PSCustomObject]@{ ImageName = $currentImageName; BlobName = $currentBlobName; Status = "Succeeded" })
            }
            else {
                throw "Deployment finished with state: $($deployment.ProvisioningState)"
            }
        }
        catch {
            Write-Host "  ERROR deploying '$currentImageName': $_" -ForegroundColor Red
            $deployResults.Add([PSCustomObject]@{ ImageName = $currentImageName; BlobName = $currentBlobName; Status = "Failed: $_" })
        }
        finally {
            if ($generatedParamsPath -and (Test-Path $generatedParamsPath)) {
                Remove-Item -Path $generatedParamsPath -Force
                Write-Host "  Cleaned up params file." -ForegroundColor DarkGray
            }
            $generatedParamsPath = $null
        }

        Write-Host ""
    }
}
catch {
    Write-Host "Fatal error: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Run Summary" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ("{0,-35} {1,-45} {2}" -f "Image Name", "Blob", "Status") -ForegroundColor Cyan
Write-Host ("-" * 110) -ForegroundColor DarkGray

foreach ($r in $deployResults) {
    $color = if ($r.Status -eq "Succeeded") { "Green" } elseif ($r.Status -like "Failed*") { "Red" } else { "Yellow" }
    Write-Host ("{0,-35} {1,-45} {2}" -f $r.ImageName, $r.BlobName, $r.Status) -ForegroundColor $color
}

Write-Host ""
$failCount = @($deployResults | Where-Object { $_.Status -like 'Failed*' }).Count
if ($failCount -gt 0) {
    Write-Host "$failCount image(s) failed. Review errors above." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "All images processed successfully." -ForegroundColor Green
}
