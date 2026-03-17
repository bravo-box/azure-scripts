# Azure Local VM Image Deployment

## Overview

This folder contains an ARM template and a PowerShell wrapper for creating Azure Local gallery images from blobs stored in Azure Storage.

The recommended workflow is to use `Deploy-AzLocalVMImage.ps1` rather than deploying the template directly. The wrapper now:

- resolves the active subscription from `Get-AzContext`
- can auto-discover the storage account resource group and subscription
- can prompt for the Azure Local custom location
- generates a temporary parameters file at runtime
- generates a read-only SAS URL for each selected blob and passes it to the template as the secure `imagePath` parameter
- supports both single-image deployment and interactive multi-image deployment from a container

Direct ARM deployment is still supported, but you must provide the secure `imagePath` value yourself.

## Files

- `deploy_azl_vmimages.json`: ARM template for `Microsoft.AzureStackHCI/galleryImages`
- `Deploy-AzLocalVMImage.ps1`: recommended deployment wrapper
- `deploy_azl_vmimages.parameters.json`: example scaffold for direct ARM deployment; not used by the wrapper script
- `README.md`: this document

## Current Behavior

### Wrapper script

`Deploy-AzLocalVMImage.ps1` supports two modes.

Single-image mode:

- provide `-ImageBlobName`
- optionally provide `-ImageName`
- if `-ImageName` is omitted, the image name is derived from the blob filename

Multi-image mode:

- omit `-ImageBlobName`
- the script lists all blobs in the selected container
- choose items with comma-separated numbers eg: `1,5,6`, ranges such as `1-3`, or `*` for all
- the script derives image names from blob names
- `-ImageNamePrefix` can prepend a prefix to all derived names

For each selected blob, the wrapper:

- verifies the blob exists
- generates a 4-hour read-only SAS
- writes a temporary parameters file
- validates the ARM template
- optionally runs `-ValidateOnly` or `-WhatIf`
- deploys the gallery image
- deletes the temporary parameters file

At the end of the run, it prints a per-image summary table.

### ARM template

The template creates `Microsoft.AzureStackHCI/galleryImages` using API version `2025-09-01-preview` and expects a secure blob URL in `imagePath`.

Important details:

- `properties.imagePath` is supplied directly from a secure parameter
- the template does not build a blob URL for you
- the template does not create or manage SAS tokens

## Prerequisites

### Azure Local

- Azure Local cluster deployed and configured
- a valid custom location for the target cluster
- required Azure Local / Arc resource providers registered
- Arc Resource Bridge online and healthy

### Storage

- source image stored in Azure Storage as a VHD or VHDX blob
- container exists and contains the image blobs you want to deploy
- storage account can be in the same or another subscription

### Local tooling

- PowerShell with `Az.Resources`
- Azure PowerShell authenticated with `Connect-AzAccount`
- Azure CLI authenticated with `az login`

### Permissions

Target deployment requires permission to create resources in the destination resource group.

Source storage access requires enough control-plane and data-plane access to:

- read storage account metadata
- enumerate blobs in the container
- read the selected blob
- generate a user-delegation SAS

If SAS generation fails, review role assignments such as:

- `Storage Blob Data Reader`
- `Storage Blob Delegator`

## Parameters

### Wrapper script parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `ResourceGroupName` | Yes | Target resource group where gallery images will be created |
| `StorageAccountName` | Yes | Source storage account name |
| `CustomLocationId` | No | Custom location resource ID; prompts if omitted |
| `StorageAccountResourceGroup` | No | Source storage resource group; auto-resolved if omitted |
| `StorageAccountSubscription` | No | Source storage subscription; auto-resolved if omitted |
| `ImageBlobName` | No | Blob to deploy in single-image mode; omit for interactive multi-image mode |
| `ImageName` | No | Explicit image name in single-image mode |
| `ImageNamePrefix` | No | Prefix added to blob-derived image names |
| `ContainerName` | No | Source container name; wrapper default is `vmimages` |
| `OsType` | No | `Windows` or `Linux`; applies to all selected blobs |
| `HyperVGeneration` | No | `V1` or `V2` |
| `ImageVersion` | No | Gallery image version |
| `Location` | No | Defaults to the target resource group location |
| `TemplatePath` | No | Path to the template file |
| `DeploymentName` | No | Base deployment name |
| `ValidateOnly` | No | Validate only; do not deploy |
| `WhatIf` | No | Preview deployment |

### ARM template parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `location` | string | No | Defaults to `resourceGroup().location` |
| `customLocationId` | string | Yes | Azure Local custom location resource ID |
| `imageName` | string | Yes | Gallery image name |
| `storageAccountName` | string | Yes | Source storage account name |
| `storageAccountResourceGroup` | string | Yes | Source storage account resource group |
| `storageAccountSubscription` | string | Yes | Source storage account subscription |
| `imagePath` | secureString | Yes | Full blob URL including SAS token |
| `containerName` | string | No | Template default is `vhds` |
| `imageBlobName` | string | Yes | Source blob name |
| `osType` | string | No | `Windows` or `Linux` |
| `hyperVGeneration` | string | No | `V1` or `V2` |
| `imageVersion` | string | No | Gallery image version |
| `tags` | object | No | Resource tags |

## Recommended Usage

### Deploy a single image

```powershell
.\Deploy-AzLocalVMImage.ps1 `
  -ResourceGroupName "my-azurelocal-rg" `
  -StorageAccountName "myimagestore" `
  -ImageBlobName "Windows2022.vhdx" `
  -ImageName "windows-server-2022"
```

### Deploy multiple images interactively

```powershell
.\Deploy-AzLocalVMImage.ps1 `
  -ResourceGroupName "my-azurelocal-rg" `
  -StorageAccountName "myimagestore" `
  -ContainerName "vmimages" `
  -ImageNamePrefix "prod-"
```

Valid selection examples at the prompt:

- `1,3,5`
- `2-4`
- `*`

### Validate only

```powershell
.\Deploy-AzLocalVMImage.ps1 `
  -ResourceGroupName "my-azurelocal-rg" `
  -StorageAccountName "myimagestore" `
  -ValidateOnly
```

### Preview with WhatIf

```powershell
.\Deploy-AzLocalVMImage.ps1 `
  -ResourceGroupName "my-azurelocal-rg" `
  -StorageAccountName "myimagestore" `
  -ImageBlobName "Ubuntu2204.vhdx" `
  -WhatIf
```

## Direct ARM Deployment

If you deploy the template directly, you must provide `imagePath` as a full SAS URL.

Example parameter file shape:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "customLocationId": {
      "value": "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ExtendedLocation/customLocations/my-custom-location"
    },
    "imageName": {
      "value": "windows-server-2022"
    },
    "storageAccountName": {
      "value": "myimagestore"
    },
    "storageAccountResourceGroup": {
      "value": "storage-rg"
    },
    "storageAccountSubscription": {
      "value": "00000000-0000-0000-0000-000000000000"
    },
    "containerName": {
      "value": "vhds"
    },
    "imageBlobName": {
      "value": "Windows2022.vhdx"
    },
    "imagePath": {
      "value": "https://myimagestore.blob.core.usgovcloudapi.net/vhds/Windows2022.vhdx?<sas-token>"
    },
    "osType": {
      "value": "Windows"
    },
    "hyperVGeneration": {
      "value": "V2"
    },
    "imageVersion": {
      "value": "1.0.0"
    }
  }
}
```

Validate:

```powershell
Test-AzResourceGroupDeployment `
  -ResourceGroupName "my-azurelocal-rg" `
  -TemplateFile .\deploy_azl_vmimages.json `
  -TemplateParameterFile .\deploy_azl_vmimages.parameters.json
```

Deploy:

```powershell
New-AzResourceGroupDeployment `
  -ResourceGroupName "my-azurelocal-rg" `
  -TemplateFile .\deploy_azl_vmimages.json `
  -TemplateParameterFile .\deploy_azl_vmimages.parameters.json `
  -Name "azl-vmimage-deployment"
```

## Naming Behavior

When `-ImageName` is omitted, the wrapper derives names from the blob filename by:

- removing the extension
- converting to lowercase
- replacing characters outside `a-z`, `0-9`, and `-` with `-`

Examples:

- `Windows2022.vhdx` -> `windows2022`
- `ubuntu-22.04-gen2.vhdx` -> `ubuntu-22-04-gen2`
- with `-ImageNamePrefix "prod-"`: `prod-ubuntu-22-04-gen2`

## Operational Notes

- The wrapper default container is `vmimages`.
- The template default container is `vhds`.
- If you use the wrapper, its value is what gets passed to the template.
- If you deploy the template directly and omit `containerName`, the template default `vhds` is used.
- The wrapper generates a 4-hour read-only SAS for each selected blob.
- The wrapper never prints the SAS value to the console.

## Troubleshooting

### No active Azure context

```powershell
Connect-AzAccount
az login
```

### Custom location not found

- verify the custom location exists in the active subscription
- provide `-CustomLocationId` explicitly if needed

### Storage account not found

- verify the storage account name
- provide `-StorageAccountSubscription` if the account is in another subscription
- provide `-StorageAccountResourceGroup` if the name is ambiguous

### Blob listing or blob read fails

- verify the container and blob names
- confirm your identity has blob data-plane access
- confirm storage firewall or network rules allow access

### SAS generation fails

- confirm Azure CLI is signed in
- confirm your identity can generate a user-delegation SAS
- check role assignments such as `Storage Blob Data Reader` and `Storage Blob Delegator`

### Azure Local / Arc bridge connectivity failures

If deployment or validation fails with appliance connectivity or Azure Local networking errors, verify the Arc Resource Bridge and custom location health first. Those failures are infrastructure issues rather than parameter-file issues.

## Outputs and Results

The ARM template currently does not define template outputs.

The wrapper script provides:

- validation messages
- per-image deployment status
- final summary table

## References

- [Azure Local Documentation](https://learn.microsoft.com/en-us/azure/azure-local/)
- [Azure Local VM Management](https://learn.microsoft.com/en-us/azure/azure-local/manage/azure-arc-vm-management-overview)
- [Azure Resource Manager Templates](https://learn.microsoft.com/en-us/azure/resource-manager/templates/overview)
- [Azure Storage Documentation](https://learn.microsoft.com/en-us/azure/storage/)