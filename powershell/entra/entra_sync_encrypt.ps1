# =========================================================
#       ENCRYPT AND STORE CREDENTIALS FOR ENTRA SYNC
# =========================================================
 
   # Secure Azure App Registration Storage Script
   # Uses DPAPI (LocalMachine) to encrypt Tenant ID, Client ID, and Client Secret
   # Values can ONLY be decrypted on this machine
   # Run this on the same server where the Entra Sync script will run

# =========================================================
#       SET VARIABLES
# =========================================================

Write-Host "== Storing encrypted Azure App Registration credentials =="

$tenantID = "YOUR-TENANT-ID"
$clientID = "YOUR-CLIENT-ID"
$clientSecret = "YOUR-CLIENT-SECRET"
$SecurePath = "C:\Secure\AzureApp"
$encryptedTenantID = "tenantId.bin"
$encryptedClientID = "clientId.bin"
$encryptedClientSecret = "clientSecret.bin"

Write-Host "== Creating secure folder =="
if (-Not (Test-Path $SecurePath)) {
    New-Item -ItemType Directory -Path $SecurePath | Out-Null
    Write-Host "Created: $SecurePath"
} else {
    Write-Host "Folder already exists."
}

Write-Host "== Hardening folder permissions (ACLs) =="
# REMOVE inheritance
icacls $SecurePath /inheritance:r | Out-Null
# ADD limited permissions
icacls $SecurePath /grant "SYSTEM:(OI)(CI)F" | Out-Null
icacls $SecurePath /grant "Administrators:(OI)(CI)F" | Out-Null

# If script runs under a specific user/service account, add it here:
# icacls $SecurePath /grant "MyServiceAccount:(OI)(CI)F"

Write-Host "Permissions secured."

function Protect-String {
    param(
        [Parameter(Mandatory)][string]$String,
        [string]$Path
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($String)

    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )

    Set-Content -Path $Path -Value $protected -Encoding Byte
}

Protect-String -String "$tenantID" -Path "$SecurePath\$encryptedTenantID"
Protect-String -String "$clientID" -Path "$SecurePath\$encryptedClientID"
Protect-String -String "$clientSecret" -Path "$SecurePath\$encryptedClientSecret"