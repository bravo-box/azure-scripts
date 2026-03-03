# This script will copy relevant and necessary files and scripts to the local node
# Any drivers that are needed for the local node eg: network drivers should be copied to the node beforehand.
# Also run some checks to ensure that the driver provider is NOT EQUAL to Microsoft.
# It will copy the booststrap script to the local node and execute it.

# Variables
$scriptPath = "C:\AzureLocalSetup"
$driverSourcePath = "https://downloads.hpe.com/pub/softlib2/software1/sc-windows/p176556484/v274622/cp068800.exe" 
$bootstrapScriptSource = "https://raw.githubusercontent.com/bravo-box/azgov-scripts/refs/heads/main/powershell/azurelocal-node-add.ps1"

# Make a directory to store the scripts
if (-Not (Test-Path -Path $scriptPath)) {
    New-Item -ItemType Directory -Path $scriptPath
}

# Copy the bootstrap script to the local node
Invoke-WebRequest -Uri $bootstrapScriptSource -OutFile "$scriptPath\azurelocal-bootstrap.ps1"

# Check for network drivers that are not Microsoft
$nonMicrosoftDrivers = get-netadapter | select-object Name, driverprovider | Format-Table -AutoSize
write-host "Here are the driver providers by network adapter:"
$nonMicrosoftDrivers | ForEach-Object { Write-Host $_ }

# Copy network drivers for your local node
Invoke-WebRequest -Uri $driverSourcePath -OutFile "$scriptPath\cp068800.exe"

