[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName = '<enter-resource-group-name>'
)

try {
    $null = Get-Command Get-AzContext, Get-AzAccessToken, Get-AzEnvironment -ErrorAction Stop
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context.Account -or -not $context.Subscription.Id -or -not $context.Tenant.Id) {
        throw 'No signed-in Azure subscription context. Run Connect-AzAccount and select a subscription with Set-AzContext first.'
    }
    $environment = Get-AzEnvironment -Name $context.Environment.Name -ErrorAction Stop
    if (-not $environment.ResourceManagerUrl) {
        throw 'The current Azure environment does not provide a Resource Manager endpoint.'
    }
} catch {
    throw "Unable to initialize Azure context. Ensure Az.Accounts is installed and you are signed in. $($_.Exception.Message)"
}

$subscriptionId = $context.Subscription.Id
$managementUrl = $environment.ResourceManagerUrl.TrimEnd('/')
$apiVersion = '2026-09-01'
$escapedResourceGroup = [Uri]::EscapeDataString($ResourceGroupName)
$resourceGroupUri = "$managementUrl/subscriptions/$subscriptionId/resourceGroups/$escapedResourceGroup"
Write-Host "Subscription: $($context.Subscription.Name) ($subscriptionId)"
Write-Host "Environment: $($context.Environment.Name); resource group: $ResourceGroupName"
Write-Warning 'Setting softwareAssuranceCustomer to true is a licensing attestation. Only proceed for eligible Windows Server licenses with active Software Assurance or qualifying subscriptions.'

function Invoke-ArcRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PUT')]
        [string]$Method,
        [Parameter(Mandatory)]
        [string]$Uri,
        [string]$Body
    )

    $requestUri = [Uri]$Uri
    $managementUri = [Uri]$managementUrl
    if (-not $requestUri.IsAbsoluteUri -or $requestUri.Scheme -ne 'https' -or
        $requestUri.Authority -ne $managementUri.Authority) {
        throw 'Refusing to send an access token outside the current Azure Resource Manager endpoint.'
    }

    $accessToken = Get-AzAccessToken -ResourceUrl $environment.ResourceManagerUrl -TenantId $context.Tenant.Id -ErrorAction Stop
    if (-not $accessToken.Token) {
        throw 'Azure returned an empty access token. Sign in again before retrying.'
    }
    $tokenText = if ($accessToken.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $accessToken.Token).Password
    } else {
        [string]$accessToken.Token
    }
    $request = @{
        Method = $Method
        Uri = $Uri
        Headers = @{ Authorization = "Bearer $tokenText" }
        ContentType = 'application/json'
        TimeoutSec = 60
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = $Body
    }
    Invoke-RestMethod @request
}

$machines = [System.Collections.Generic.List[object]]::new()
$visitedPages = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$listUri = "$resourceGroupUri/providers/Microsoft.HybridCompute/machines?api-version=$apiVersion"
try {
    do {
        if (-not $visitedPages.Add($listUri)) {
            throw 'Azure returned a repeated pagination URL.'
        }
        $response = Invoke-ArcRequest -Method GET -Uri $listUri
        if ($null -eq $response -or $null -eq $response.value) {
            throw 'The machine list response does not contain a value array.'
        }
        foreach ($machine in $response.value) {
            $machines.Add($machine)
        }
        $listUri = $response.nextLink
    } while ($listUri)
} catch {
    throw "Unable to list Arc machines in subscription $subscriptionId, resource group $ResourceGroupName. $($_.Exception.Message)"
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($machine in $machines) {
    $machineName = $machine.name
    $result = [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceGroup = $ResourceGroupName
        MachineName = $machineName
        Status = 'Skipped'
        Message = ''
    }
    if ($machine.properties.osType -ine 'Windows') {
        $result.Message = 'Not a reported Windows machine.'
    } elseif ([string]::IsNullOrWhiteSpace($machineName) -or [string]::IsNullOrWhiteSpace($machine.location)) {
        $result.Status = 'Failed'
        $result.Message = 'The machine is missing its name or location.'
    } elseif ($machine.properties.status -ine 'Connected') {
        $result.Message = 'The machine is not connected; benefits enrollment requires connectivity.'
    } elseif (-not $PSCmdlet.ShouldProcess("$subscriptionId/$ResourceGroupName/$machineName", 'Attest Windows Server Software Assurance benefits')) {
        $result.Message = 'No change requested (WhatIf or confirmation declined).'
    } else {
        try {
            $escapedMachineName = [Uri]::EscapeDataString($machineName)
            $uri = "$resourceGroupUri/providers/Microsoft.HybridCompute/machines/$escapedMachineName/licenseProfiles/default?api-version=$apiVersion"
            $json = @{
                location = $machine.location
                properties = @{
                    softwareAssurance = @{ softwareAssuranceCustomer = $true }
                }
            } | ConvertTo-Json -Depth 5
            $updateResponse = Invoke-ArcRequest -Method PUT -Uri $uri -Body $json
            if ($updateResponse.properties.softwareAssurance.softwareAssuranceCustomer -ne $true) {
                $updateResponse = Invoke-ArcRequest -Method GET -Uri $uri
                if ($updateResponse.properties.softwareAssurance.softwareAssuranceCustomer -ne $true) {
                    throw 'The update was accepted but the Software Assurance attestation could not be verified. Check the license profile before retrying.'
                }
            }
            $result.Status = 'Updated'
            $result.Message = 'Software Assurance attestation verified; benefit activation may take several minutes and depends on regional availability.'
        } catch {
            $result.Status = 'Failed'
            $result.Message = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            Write-Warning "Failed to update ${machineName}: $($result.Message)"
        }
    }
    $results.Add($result)
}

$updatedCount = @($results | Where-Object Status -eq 'Updated').Count
$skippedCount = @($results | Where-Object Status -eq 'Skipped').Count
$failedCount = @($results | Where-Object Status -eq 'Failed').Count
$results
Write-Host "Summary: $($machines.Count) machines; $updatedCount updated; $skippedCount skipped; $failedCount failed."
if ($failedCount -gt 0) {
    throw "$failedCount machine(s) failed. Review the per-machine results before retrying."
}
