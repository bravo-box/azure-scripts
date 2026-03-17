# Usage Instructions

1. Download the ps1 and config.json to local machine
2. Update your config.json file with your logical network configurations.

Example:

``` json
{
  "location": "usgovvirginia",
  "logicalNetworks": [
    {
      "name": "mylocal-lnet-static-01",
      "ipAllocationMethod": "Static",
      "addressPrefixes": "192.168.180.0/24",
      "gateway": "192.168.180.1",
      "dnsServers": "192.168.180.222",
      "vlan": 201
    },
    {
      "name": "mylocal-lnet-static-02",
      "ipAllocationMethod": "Static",
      "addressPrefixes": "192.168.181.0/24",
      "gateway": "192.168.181.1",
      "dnsServers": "192.168.181.222",
      "vlan": 202
    },
    {
      "name": "mylocal-lnet-static-03",
      "ipAllocationMethod": "Static",
      "addressPrefixes": "192.168.182.0/24",
      "gateway": "192.168.182.1",
      "dnsServers": "192.168.182.222",
      "vlan": 203
    }
  ]
}
```

NOTE: you can add as many logical networks as you need, just add a new object defining your logical network.

3. Log into Azure with the appropriate credentials which has access to create logical networks on the Azure Local.
4. Ensure that your context is set to the subscription for the Azure Local that you want to deploy to.
5. Run the pwsh file, enter the resource group where you want to logical network resource to deploy to. These do not need to be in the same RG as your cluster. 
6. You will prompted for a custom location you want to be connected, select the corresponding number.
7. If the script cannot find any other logical networks you will be prompted to enter your VMSwitch name. In Azure Local it is usually something like this: ```ConvergedSwitch(compute_management)```

