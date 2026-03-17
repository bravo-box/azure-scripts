# =========================================
#       SETTING UP VARIABLES
# =========================================

$GroupName = "AD_Security_Group_Name"
$OU = "OU=,DC=,DC="
$LogDirectory = "C:\Logs\EntraToADSync"
$EventLogName = "EntraToADSync"
$EventSource  = "EntraToADSyncScript"
$Pass = ""  # Default password for new users
$secureFolder = "C:\Secure\AzureApp"
$encryptedTenantId = "tenantId.bin"
$encryptedClientId = "clientId.bin"
$encryptedClientSecret = "clientSecret.bin"

# =========================================
#       SETUP DECRYPTION FUNCTION
# =========================================

function Unprotect-String {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $protected = Get-Content -Path $Path -Encoding Byte

    $unprotected = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )

    return [System.Text.Encoding]::UTF8.GetString($unprotected)
}

$tenantID = Unprotect-String -Path "$secureFolder\$encryptedTenantId"
$clientID = Unprotect-String -Path "$secureFolder\$encryptedClientId"
$clientSecret = Unprotect-String -Path "$secureFolder\$encryptedClientSecret"

# =========================================
#       LOGGING SETUP (FILE + JSON)
# =========================================
$TextLogFile = "$LogDirectory\SyncLog_$(Get-Date -Format 'yyyy-MM-dd').log"
$JsonLogFile = "$LogDirectory\SyncLog_$(Get-Date -Format 'yyyy-MM-dd').json"

if (!(Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory | Out-Null
}

# =========================================
#       EVENT VIEWER LOG SETUP
# =========================================
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    New-EventLog -LogName $EventLogName -Source $EventSource
} else {
    # Ensure the log name matches the existing source
    $currentLog = [System.Diagnostics.EventLog]::LogNameFromSourceName($EventSource, ".")
    if ($currentLog -ne $EventLogName) {
        Write-Warning "Event source '$EventSource' already exists under log '$currentLog'."
    }
}

# =========================================
#            WRITE-LOG FUNCTION
# =========================================
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$User = "",
        [string]$Operation = "",
        [string]$Exception = ""
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    # Build JSON log structure
    $logObject = [PSCustomObject]@{
        timestamp = $timestamp
        level     = $Level
        message   = $Message
        user      = $User
        operation = $Operation
        exception = $Exception
    }

    $json = $logObject | ConvertTo-Json -Depth 5

    # Write JSON log
    Add-Content -Path $JsonLogFile -Value ($json + "`n")

    # Write Text log
    $logLine = "[$timestamp] [$Level] $Message"
    Add-Content -Path $TextLogFile -Value $logLine

    # Write Console Output
    switch ($Level) {
        "INFO"  { Write-Host $logLine -ForegroundColor White }
        "WARN"  { Write-Host $logLine -ForegroundColor Yellow }
        "ERROR" { Write-Host $logLine -ForegroundColor Red }
    }

    # Event Viewer Logging
    switch ($Level) {
        "INFO"  { Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType Information -EventId 1000 -Message $Message }
        "WARN"  { Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType Warning     -EventId 2000 -Message $Message }
        "ERROR" { Write-EventLog -LogName $EventLogName -Source $EventSource -EntryType Error       -EventId 3000 -Message "$Message `nException: $Exception" }
    }
}

Write-Log "=== Starting Entra ID → Active Directory Sync ==="

# =========================================
#       GRAPH CONNECTION
# =========================================

$secureClientSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force

$ClientSecretCredential = New-Object System.Management.Automation.PSCredential ($clientID, $secureClientSecret)

Write-Log "Connecting to Microsoft Graph…" "INFO" "" "ConnectGraph"

try {
    Connect-MgGraph -Environment USGov -TenantId $tenantId -ClientSecretCredential $ClientSecretCredential -ErrorAction Stop
    Write-Log "Connected to Microsoft Graph" "INFO" "" "ConnectGraph"
}
catch {
    Write-Log "Failed to connect to MS Graph" "ERROR" "" "ConnectGraph" $_.Exception.Message
    exit
}

# =========================================
#       GET GROUP MEMBERS
# =========================================
$Group = Get-MgGroup -Filter "DisplayName eq '$GroupName'"

if (!$Group) {
    Write-Log "Group '$GroupName' not found." "ERROR" "" "GetGroup"
    exit
}

Write-Log "Group found: $GroupName (ID: $($Group.Id))" "INFO" "" "GetGroup"

$Users = Get-MgGroupMember -GroupId $Group.Id -All | ForEach-Object {
    Get-MgUser -UserId $_.Id -Property DisplayName,UserPrincipalName,Mail,GivenName,Surname
}

Write-Log "Retrieved $($Users.Count) users from Entra ID" "INFO" "" "GetGroupMembers"

# =========================================
#       SYNC USERS TO AD
# =========================================
foreach ($User in $Users) {
    $UPN = $User.UserPrincipalName
    $Name = $User.DisplayName

    Write-Log "Processing user $Name ($UPN)" "INFO" $UPN "ProcessUser"

    if (-not $UPN) {
        Write-Log "Skipping user (no UPN): $Name" "WARN" $Name "Validation"
        continue
    }

    $SamAccountName = if ($User.Mail) { ($User.Mail -split "@")[0] } else { ($UPN -split "@")[0] }
    $ExistingUser = Get-ADUser -Filter { SamAccountName -eq $SamAccountName } -ErrorAction SilentlyContinue

    if ($ExistingUser) {
        Write-Log "User already exists in AD: $SamAccountName" "INFO" $UPN "ExistsCheck"
        continue
    }

    Write-Log "Creating AD user: $SamAccountName" "INFO" $UPN "CreateUser"

    try {
        New-ADUser -SamAccountName $SamAccountName `
                   -UserPrincipalName $UPN `
                   -Name $Name `
                   -GivenName $User.GivenName `
                   -Surname $User.Surname `
                   -EmailAddress $User.Mail `
                   -Path $OU `
                   -AccountPassword (ConvertTo-SecureString "$Pass" -AsPlainText -Force) `
                   -ChangePasswordAtLogon $true `
                   -Enabled $true

        Write-Log "User created successfully: $SamAccountName" "INFO" $UPN "CreateUser"
    }
    catch {
        Write-Log "FAILED to create AD user: $SamAccountName" "ERROR" $UPN "CreateUser" $_.Exception.Message
    }
}

Disconnect-MgGraph
Write-Log "=== Sync Completed ===" "INFO" "" "Complete"
