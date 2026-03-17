# In this script you will need to run as an authenticated user to Azure
# Update the .\create-azl-lnet.config.json file with the desired configuration for your logical network(s)
# subscriptionId/resourceGroup/vmSwitchName are resolved interactively at runtime

param(
	[Parameter(Mandatory = $false)]
	[string]$ConfigPath = "$PSScriptRoot/create-azl-lnet.config.json",

	[Parameter(Mandatory = $false)]
	[switch]$UpdateIfExists,

	[Parameter(Mandatory = $false)]
	[switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AzCliJson {
	param(
		[Parameter(Mandatory = $true)]
		[string[]]$Args
	)

	$output = az @Args --output json 2>&1
	if ($LASTEXITCODE -ne 0) {
		throw "Azure CLI command failed: az $($Args -join ' ')`n$output"
	}

	if (-not $output) {
		return $null
	}

	return $output | ConvertFrom-Json
}

function Test-AzCliReady {
	try {
		$null = Invoke-AzCliJson -Args @("account", "show")
	}
	catch {
		throw "Azure CLI is not ready. Run 'az login' and ensure the stack-hci-vm extension is installed. Details: $($_.Exception.Message)"
	}
}

function Get-CurrentSubscriptionId {
	$account = Invoke-AzCliJson -Args @("account", "show", "--query", "{id:id}")
	if (-not $account -or -not $account.id) {
		throw "Unable to determine current subscription from Azure CLI context."
	}

	return [string]$account.id
}

function Test-ResourceGroupExists {
	param(
		[Parameter(Mandatory = $true)]
		[string]$SubscriptionId,

		[Parameter(Mandatory = $true)]
		[string]$ResourceGroup
	)

	$cliArgs = @(
		"group", "exists",
		"--subscription", $SubscriptionId,
		"--name", $ResourceGroup,
		"--output", "tsv"
	)

	$result = az @cliArgs 2>&1
	if ($LASTEXITCODE -ne 0) {
		throw "Unable to validate resource group '$ResourceGroup'. Azure CLI output: $result"
	}

	return ([string]$result).Trim().ToLowerInvariant() -eq "true"
}

function Resolve-ResourceGroup {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[Parameter(Mandatory = $true)]
		[bool]$HasResourceGroup
	)

	if ($HasResourceGroup -and -not (Test-IsBlankOrPlaceholder -Value $Config.resourceGroup)) {
		if (Test-ResourceGroupExists -SubscriptionId $Config.subscriptionId -ResourceGroup $Config.resourceGroup) {
			return
		}

		Write-Host "Configured resource group '$($Config.resourceGroup)' was not found in subscription '$($Config.subscriptionId)'."
	}

	while ($true) {
		$inputResourceGroup = Read-Host "Enter Azure resource group name"
		if (-not $inputResourceGroup) {
			Write-Host "Resource group is required."
			continue
		}

		if (Test-ResourceGroupExists -SubscriptionId $Config.subscriptionId -ResourceGroup $inputResourceGroup) {
			if ($HasResourceGroup) {
				$config.resourceGroup = $inputResourceGroup
			}
			else {
				$config | Add-Member -NotePropertyName resourceGroup -NotePropertyValue $inputResourceGroup
			}
			return
		}

		Write-Host "Resource group '$inputResourceGroup' was not found in subscription '$($config.subscriptionId)'. Try again."
	}
}

function Test-IsBlankOrPlaceholder {
	param(
		[Parameter(Mandatory = $false)]
		[AllowNull()]
		[object]$Value
	)

	if ($null -eq $Value) {
		return $true
	}

	$text = [string]$Value
	if ([string]::IsNullOrWhiteSpace($text)) {
		return $true
	}

	$text = $text.Trim()
	if ($text -match '^<[^>]+>$') {
		return $true
	}

	return $false
}

function Get-LnetByName {
	param(
		[Parameter(Mandatory = $true)]
		[string]$Subscription,

		[Parameter(Mandatory = $true)]
		[string]$ResourceGroup,

		[Parameter(Mandatory = $true)]
		[string]$Name
	)

	$existing = Invoke-AzCliJson -Args @(
		"stack-hci-vm", "network", "lnet", "list",
		"--subscription", $Subscription,
		"--resource-group", $ResourceGroup,
		"--query", "[?name=='$Name'] | [0]"
	)

	return $existing
}

function Resolve-CustomLocationId {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config
	)

	$hasCustomLocationId = $null -ne $Config.PSObject.Properties['customLocationId']

	function Select-CustomLocationFromAzure {
		param(
			[Parameter(Mandatory = $true)]
			[pscustomobject]$Cfg
		)

		$query = "[].{name:name,id:id,location:location,resourceGroup:resourceGroup}"
		$cliArgs = @(
			"resource", "list",
			"--subscription", $Cfg.subscriptionId,
			"--resource-type", "Microsoft.ExtendedLocation/customLocations",
			"--query", $query
		)

		$customLocations = @(Invoke-AzCliJson -Args $cliArgs)

		if (-not $customLocations -or $customLocations.Count -eq 0) {
			throw "No Custom Locations found in subscription '$($Cfg.subscriptionId)'."
		}

		Write-Host "Available Azure Local Custom Locations:"
		for ($i = 0; $i -lt $customLocations.Count; $i++) {
			$index = $i + 1
			$item = $customLocations[$i]
			Write-Host ("[{0}] {1}  (RG: {2}, Location: {3})" -f $index, $item.name, $item.resourceGroup, $item.location)
		}

		while ($true) {
			$selection = Read-Host "Select Custom Location by number (1-$($customLocations.Count))"
			$selectedIndex = 0
			if ([int]::TryParse($selection, [ref]$selectedIndex)) {
				if ($selectedIndex -ge 1 -and $selectedIndex -le $customLocations.Count) {
					$chosen = $customLocations[$selectedIndex - 1]
					Write-Host "Selected Custom Location: $($chosen.name)"
					return [string]$chosen.id
				}
			}

			Write-Host "Invalid selection. Enter a number between 1 and $($customLocations.Count)."
		}
	}

	if ($hasCustomLocationId -and $Config.customLocationId) {
		return [string]$Config.customLocationId
	}

	return Select-CustomLocationFromAzure -Cfg $Config
}

function Get-DiscoveredVmSwitchNames {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[Parameter(Mandatory = $true)]
		[string]$CustomLocationId
	)

	$logicalNetworks = @(Invoke-AzCliJson -Args @(
		"stack-hci-vm", "network", "lnet", "list",
		"--subscription", $Config.subscriptionId,
		"--resource-group", $Config.resourceGroup
	))

	$names = @()
	$expectedCustomLocation = $CustomLocationId.Trim().ToLowerInvariant()

	foreach ($ln in $logicalNetworks) {
		$lnCustomLocation = $null
		if ($ln.PSObject.Properties['extendedLocation'] -and $ln.extendedLocation -and $ln.extendedLocation.PSObject.Properties['name']) {
			$lnCustomLocation = [string]$ln.extendedLocation.name
		}

		if (Test-IsBlankOrPlaceholder -Value $lnCustomLocation) {
			continue
		}

		if ($lnCustomLocation.Trim().ToLowerInvariant() -ne $expectedCustomLocation) {
			continue
		}

		$switchName = $null
		if ($ln.PSObject.Properties['properties'] -and $ln.properties -and $ln.properties.PSObject.Properties['vmSwitchName']) {
			$switchName = [string]$ln.properties.vmSwitchName
		}

		if (-not (Test-IsBlankOrPlaceholder -Value $switchName)) {
			$names += $switchName.Trim()
		}
	}

	return @($names | Sort-Object -Unique)
}

function Resolve-VmSwitchName {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[Parameter(Mandatory = $true)]
		[pscustomobject]$Network,

		[Parameter(Mandatory = $true)]
		[string]$CustomLocationId
	)

	$hasVmSwitchName = $null -ne $Network.PSObject.Properties['vmSwitchName']
	if ($hasVmSwitchName -and -not (Test-IsBlankOrPlaceholder -Value $Network.vmSwitchName)) {
		return
	}

	$discovered = @(Get-DiscoveredVmSwitchNames -Config $Config -CustomLocationId $CustomLocationId)

	if ($discovered.Count -eq 1) {
		$resolved = $discovered[0]
		if ($hasVmSwitchName) {
			$Network.vmSwitchName = $resolved
		}
		else {
			$Network | Add-Member -NotePropertyName vmSwitchName -NotePropertyValue $resolved
		}
		Write-Host "vmSwitchName not provided for '$($Network.name)'. Using discovered switch: $resolved"
		return
	}

	if ($discovered.Count -gt 1) {
		Write-Host "Multiple vmSwitchName values discovered for custom location."
		for ($i = 0; $i -lt $discovered.Count; $i++) {
			Write-Host ("[{0}] {1}" -f ($i + 1), $discovered[$i])
		}

		while ($true) {
			$selection = Read-Host "Select vmSwitchName by number (1-$($discovered.Count))"
			$selectedIndex = 0
			if ([int]::TryParse($selection, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $discovered.Count) {
				$resolved = $discovered[$selectedIndex - 1]
				if ($hasVmSwitchName) {
					$Network.vmSwitchName = $resolved
				}
				else {
					$Network | Add-Member -NotePropertyName vmSwitchName -NotePropertyValue $resolved
				}
				Write-Host "Selected vmSwitchName for '$($Network.name)': $resolved"
				return
			}

			Write-Host "Invalid selection. Enter a number between 1 and $($discovered.Count)."
		}
	}

	while ($true) {
		$manualSwitch = Read-Host "Enter vmSwitchName for '$($Network.name)'"
		if (-not (Test-IsBlankOrPlaceholder -Value $manualSwitch)) {
			$manualSwitch = $manualSwitch.Trim()
			if ($hasVmSwitchName) {
				$Network.vmSwitchName = $manualSwitch
			}
			else {
				$Network | Add-Member -NotePropertyName vmSwitchName -NotePropertyValue $manualSwitch
			}
			return
		}

		Write-Host "vmSwitchName is required."
	}
}

function Confirm-LogicalNetwork {
	param(
		[Parameter(Mandatory = $true)]
		[pscustomobject]$Config,

		[Parameter(Mandatory = $true)]
		[pscustomobject]$Network,

		[Parameter(Mandatory = $true)]
		[string]$CustomLocationId,

		[Parameter(Mandatory = $true)]
		[bool]$AllowUpdate,

		[Parameter(Mandatory = $true)]
		[bool]$PreviewOnly
	)

	$existing = Get-LnetByName -Subscription $Config.subscriptionId -ResourceGroup $Config.resourceGroup -Name $Network.name
	$action = if ($existing) { "update" } else { "create" }

	if ($action -eq "update" -and -not $AllowUpdate) {
		Write-Host "[SKIP] Logical network '$($Network.name)' already exists. Use -UpdateIfExists to apply updates."
		return
	}

	$cliArgs = @(
		"stack-hci-vm", "network", "lnet", $action,
		"--subscription", $Config.subscriptionId,
		"--resource-group", $Config.resourceGroup,
		"--custom-location", $CustomLocationId,
		"--location", $Config.location,
		"--name", $Network.name,
		"--vm-switch-name", ([string]$Network.vmSwitchName).Trim('"'),
		"--ip-allocation-method", $Network.ipAllocationMethod,
		"--address-prefixes", $Network.addressPrefixes,
		"--gateway", $Network.gateway,
		"--dns-servers", $Network.dnsServers,
		"--vlan", [string]$Network.vlan
	)

	if ($PreviewOnly) {
		Write-Host "[WHATIF] az $($cliArgs -join ' ')"
		return
	}

	Write-Host "[$($action.ToUpper())] Logical network '$($Network.name)'"
	$null = Invoke-AzCliJson -Args $cliArgs
}

if (-not (Test-Path -Path $ConfigPath)) {
	throw "Config file not found: $ConfigPath"
}

Test-AzCliReady

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$hasSubscriptionId = $null -ne $config.PSObject.Properties['subscriptionId']
$hasResourceGroup = $null -ne $config.PSObject.Properties['resourceGroup']
$hasLocation = $null -ne $config.PSObject.Properties['location']
$hasLogicalNetworks = $null -ne $config.PSObject.Properties['logicalNetworks']

if (-not $hasSubscriptionId -or (Test-IsBlankOrPlaceholder -Value $config.subscriptionId)) {
	$subscriptionId = Get-CurrentSubscriptionId
	if ($hasSubscriptionId) {
		$config.subscriptionId = $subscriptionId
	}
	else {
		$config | Add-Member -NotePropertyName subscriptionId -NotePropertyValue $subscriptionId
	}
	Write-Host "subscriptionId not provided in config. Using current az context subscription: $subscriptionId"
}

Resolve-ResourceGroup -Config $config -HasResourceGroup $hasResourceGroup

if (-not $hasLocation -or (Test-IsBlankOrPlaceholder -Value $config.location)) {
	$inputLocation = Read-Host "Enter Azure region/location (example: eastus)"
	if (-not $inputLocation) {
		throw "Region/location is required."
	}

	if ($hasLocation) {
		$config.location = $inputLocation
	}
	else {
		$config | Add-Member -NotePropertyName location -NotePropertyValue $inputLocation
	}
}

if (-not $hasLogicalNetworks -or -not $config.logicalNetworks -or $config.logicalNetworks.Count -eq 0) {
	throw "Config must include at least one entry in 'logicalNetworks'."
}

$customLocationId = Resolve-CustomLocationId -Config $config

Write-Host "====================================="
Write-Host "Starting logical network deployment"
Write-Host "====================================="
Write-Host "Subscription : $($config.subscriptionId)"
Write-Host "ResourceGroup: $($config.resourceGroup)"
Write-Host "Location     : $($config.location)"
Write-Host "CustomLocId  : $customLocationId"
Write-Host "NetworkCount : $($config.logicalNetworks.Count)"

foreach ($network in $config.logicalNetworks) {
	if (-not $network.name) { throw "Each logical network requires 'name'." }
	Resolve-VmSwitchName -Config $config -Network $network -CustomLocationId $customLocationId
	if (Test-IsBlankOrPlaceholder -Value $network.vmSwitchName) { throw "Logical network '$($network.name)' is missing 'vmSwitchName'." }
	if (-not $network.addressPrefixes) { throw "Logical network '$($network.name)' is missing 'addressPrefixes'." }
	if (-not $network.gateway) { throw "Logical network '$($network.name)' is missing 'gateway'." }
	if (-not $network.dnsServers) { throw "Logical network '$($network.name)' is missing 'dnsServers'." }
	if (-not $network.vlan) { throw "Logical network '$($network.name)' is missing 'vlan'." }

	if (-not $network.ipAllocationMethod) {
		$network | Add-Member -NotePropertyName ipAllocationMethod -NotePropertyValue "Static"
	}

	Confirm-LogicalNetwork -Config $config -Network $network -CustomLocationId $customLocationId -AllowUpdate $UpdateIfExists.IsPresent -PreviewOnly $WhatIf.IsPresent
}

Write-Host "====================================="
Write-Host "Logical network deployment complete."
Write-Host "====================================="
