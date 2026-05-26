<#
.SYNOPSIS
    Enables NVIDIA GPUs using Discrete Device Assignment (DDA) on Azure Local hosts.
    
.DESCRIPTION
    This script automates the process of preparing NVIDIA GPUs for DDA according to 
    Microsoft's GPU preparation guidance:
    https://learn.microsoft.com/en-us/azure/azure-local/manage/gpu-preparation
    
    The script performs the following steps:
    1. Identifies GPUs in error state on the host
    2. Disables and dismounts GPU devices
    3. Downloads the NVIDIA mitigation driver
    4. Installs the mitigation driver
    5. Verifies the installation
    
.PARAMETER GPUModelInstances
    Array of GPU instance IDs to prepare. If not provided, script will auto-detect.
    Example: @("PCI\VEN_10DE&DEV_25B6&SUBSYS_157E10DE&REV_A1\4&23AD3A43&0&0010")
    
.PARAMETER DriverDownloadUrl
    URL to download the NVIDIA mitigation driver.
    Original Default: https://docs.nvidia.com/datacenter/tesla/gpu-passthrough/nvidia_azure_stack_inf_v2022.10.13_public.zip
    Update Default: https://docs.nvidia.com/datacenter/tesla/gpu-passthrough/Azure_Local_Mitigation_092525.zip
    
.PARAMETER DownloadPath
    Path where driver will be downloaded and extracted.
    Default: C:\nvidia-dda-prep
    
.PARAMETER SkipDownload
    If $true, skips downloading driver (useful if already downloaded).
    
.EXAMPLE
    # Run with auto-detection
    .\enable-nvidia-dda.ps1
    
.EXAMPLE
    # Run with specific GPU instances
    $gpus = @("PCI\VEN_10DE&DEV_25B6&SUBSYS_157E10DE&REV_A1\4&23AD3A43&0&0010")
    .\enable-nvidia-dda.ps1 -GPUModelInstances $gpus
    
.EXAMPLE
    # Run without downloading driver (already have it)
    .\enable-nvidia-dda.ps1 -SkipDownload $true
    
.NOTES
    - This script must be run as Administrator
    - Ensure no host driver is installed before running this script
    - Changes require system restart in some cases
    - Tested on Azure Local environments
    
.AUTHOR
    Azure Local GPU Preparation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$GPUModelInstances,
    
    [Parameter(Mandatory = $false)]
    [string]$DriverDownloadUrl = "https://docs.nvidia.com/datacenter/tesla/gpu-passthrough/Azure_Local_Mitigation_092525.zip",
    
    [Parameter(Mandatory = $false)]
    [string]$DownloadPath = "C:\AzureLocalSetup",
    
    [Parameter(Mandatory = $false)]
    [bool]$SkipDownload = $false
)

# Check for admin privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator"
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure Local NVIDIA GPU DDA Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Create working directory
if (-not (Test-Path $DownloadPath)) {
    Write-Host "Creating working directory: $DownloadPath" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $DownloadPath -Force | Out-Null
}

Set-Location $DownloadPath

# Step 1: Find GPUs in error state
Write-Host ""
Write-Host "[STEP 1] Finding GPUs in error state..." -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
$errorDevices = Get-PnpDevice -Status Error

$gpus = $errorDevices | Where-Object { $_.Class -like "*Video*" -or $_.FriendlyName -like "*3D Video Controller*" }

if ($gpus.Count -eq 0) {
    Write-Host "No GPUs in error state found." -ForegroundColor Yellow
    Write-Host "Checking if GPUs are already configured..." -ForegroundColor Yellow
    $configuredGPUs = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -like "*NVIDIA*" }
    if ($configuredGPUs.Count -gt 0) {
        Write-Host "Found $($configuredGPUs.Count) configured NVIDIA GPU(s):" -ForegroundColor Green
        $configuredGPUs | Format-Table -Property FriendlyName, InstanceId
    }
    else {
        Write-Host "No NVIDIA GPUs found. Please verify hardware and drivers." -ForegroundColor Yellow
    }
}
else {
    Write-Host "Found $($gpus.Count) GPU(s) in error state:" -ForegroundColor Yellow
    $gpus | Format-Table -Property FriendlyName, InstanceId
    Write-Host ""
    
    # Use auto-detected GPUs if not provided
    if (-not $GPUModelInstances) {
        $GPUModelInstances = $gpus.InstanceId
    }
    
    # Step 2: Disable and dismount GPUs
    Write-Host "[STEP 2] Disabling and dismounting GPUs..." -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    
    foreach ($id in $GPUModelInstances) {
        Write-Host "Processing GPU: $id" -ForegroundColor Cyan
        
        try {
            # Disable device
            Write-Host "  - Disabling device..." -ForegroundColor Gray
            Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
            Start-Sleep -Seconds 2
            
            # Dismount from host
            Write-Host "  - Dismounting from host..." -ForegroundColor Gray
            Dismount-VMHostAssignableDevice -InstancePath $id -Force -ErrorAction Stop
            Write-Host "  - Successfully dismounted" -ForegroundColor Green
        }
        catch {
            Write-Host "  - Error processing GPU: $_" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    
    # Verify dismount
    Write-Host "[VERIFICATION] Checking dismount status..." -ForegroundColor Green
    $unknownDevices = Get-PnpDevice -Status Unknown
    $unknownGPUs = $unknownDevices | Where-Object { $_.Class -like "*Video*" -or $_.FriendlyName -like "*3D Video Controller*" }
    
    if ($unknownGPUs.Count -gt 0) {
        Write-Host "Confirmed: $($unknownGPUs.Count) GPU(s) in Unknown state (dismounted):" -ForegroundColor Green
        $unknownGPUs | Format-Table -Property FriendlyName, InstanceId
    }
    
    Write-Host ""
}

# Step 3: Download NVIDIA mitigation driver
if (-not $SkipDownload) {
    Write-Host "[STEP 3] Downloading NVIDIA mitigation driver..." -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    Write-Host "URL: $DriverDownloadUrl" -ForegroundColor Cyan
    
    $zipFileName = Split-Path $DriverDownloadUrl -Leaf
    $zipFilePath = Join-Path $DownloadPath $zipFileName
    
    if (Test-Path $zipFilePath) {
        Write-Host "Driver already downloaded: $zipFilePath" -ForegroundColor Yellow
    }
    else {
        try {
            Write-Host "Downloading driver..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri $DriverDownloadUrl -OutFile $zipFilePath -ErrorAction Stop
            Write-Host "Download complete!" -ForegroundColor Green
        }
        catch {
            Write-Host "Error downloading driver: $_" -ForegroundColor Red
            exit 1
        }
    }
    
    Write-Host ""
    
    # Step 4: Extract driver
    Write-Host "[STEP 4] Extracting NVIDIA driver files..." -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Green
    
    $extractPath = Join-Path $DownloadPath "nvidia-mitigation-driver"
    
    if (Test-Path $extractPath) {
        Write-Host "Driver already extracted: $extractPath" -ForegroundColor Yellow
    }
    else {
        try {
            Write-Host "Extracting to: $extractPath" -ForegroundColor Cyan
            Expand-Archive $zipFilePath -DestinationPath $extractPath -ErrorAction Stop
            Write-Host "Extraction complete!" -ForegroundColor Green
        }
        catch {
            Write-Host "Error extracting driver: $_" -ForegroundColor Red
            exit 1
        }
    }
    
    Write-Host ""
}
else {
    Write-Host "[STEP 3] Skipping driver download (already available)" -ForegroundColor Yellow
    Write-Host ""
}

# Step 5: Install mitigation driver
Write-Host "[STEP 5] Installing NVIDIA mitigation driver..." -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

$extractPath = Join-Path $DownloadPath "nvidia-mitigation-driver"

if (Test-Path $extractPath) {
    Get-ChildItem $extractPath -Filter "*.inf" | ForEach-Object {
        Write-Host "Found driver: $($_.Name)" -ForegroundColor Cyan
    }
    
    # List available GPU model drivers
    Write-Host ""
    Write-Host "Available GPU model drivers:" -ForegroundColor Yellow
    Get-ChildItem $extractPath -Filter "*_base.inf" | ForEach-Object {
        $modelName = $_.Name -replace "_base.inf", "" -replace "nvidia_azure_stack_", ""
        $fullName = $_.Name
        Write-Host "  - $($modelName): $($fullName)"
    }
    
    Write-Host ""
    Write-Host "Common GPU models: T4, A2, A10, A16, A40, L4, L40, L40S, RTX6000" -ForegroundColor Yellow
    
    # Prompt for GPU model or auto-detect from directory
    $gpuModel = Read-Host "Enter GPU model (e.g., A2, T4, A16) or press Enter to skip installation"
    
    if ($gpuModel) {
        $driverFile = Join-Path $extractPath "nvidia_azure_stack_$($gpuModel)_base.inf"
        
        if (Test-Path $driverFile) {
            try {
                Write-Host "Installing driver: $driverFile" -ForegroundColor Cyan
                pnputil /add-driver $driverFile /install /force
                Write-Host "Driver installation complete!" -ForegroundColor Green
            }
            catch {
                Write-Host "Error installing driver: $_" -ForegroundColor Red
            }
        }
        else {
            Write-Host "Driver file not found: $driverFile" -ForegroundColor Red
            Write-Host "Available drivers:" -ForegroundColor Yellow
            Get-ChildItem $extractPath -Filter "*_base.inf" | ForEach-Object {
                Write-Host "  - $($_.FullName)"
            }
        }
    }
}
else {
    Write-Host "Driver extraction path not found: $extractPath" -ForegroundColor Red
    Write-Host "Please ensure driver was extracted successfully." -ForegroundColor Yellow
}

Write-Host ""

# Step 6: Verification
Write-Host "[STEP 6] Verifying NVIDIA GPU installation..." -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

Write-Host ""
Write-Host "Configured NVIDIA GPUs:" -ForegroundColor Cyan
$nvidiaGPUs = Get-PnpDevice -Class Display | Where-Object { $_.FriendlyName -like "*NVIDIA*" }

if ($nvidiaGPUs) {
    $nvidiaGPUs | Format-Table -Property FriendlyName, InstanceId
    Write-Host "GPU configuration command (pnputil):" -ForegroundColor Cyan
    pnputil /enum-devices | Select-String -Pattern "NVIDIA" -Context 5
}
else {
    Write-Host "No NVIDIA GPUs currently configured in Display class." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Device Manager enumeration:" -ForegroundColor Cyan
try {
    pnputil /scan-devices
    Write-Host "Device scan complete - check Device Manager for NVIDIA GPUs" -ForegroundColor Green
}
catch {
    Write-Host "Note: Could not execute pnputil scan" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Azure Local NVIDIA GPU DDA Setup Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Green
Write-Host "  1. Review GPU configuration in Device Manager" -ForegroundColor White
Write-Host "  2. Restart the system if required" -ForegroundColor White
Write-Host "  3. Verify GPUs appear correctly after restart" -ForegroundColor White
Write-Host "  4. Configure VM GPU assignments in Hyper-V" -ForegroundColor White
Write-Host ""
Write-Host "Reference: https://learn.microsoft.com/en-us/azure/azure-local/manage/gpu-preparation" -ForegroundColor Gray
