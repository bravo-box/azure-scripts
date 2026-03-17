# Arc-Enabled Kubernetes Bash Scripts

## Overview

This folder contains helper scripts for common Azure Arc-enabled Kubernetes tasks in Azure Local environments:

- create a Kubernetes token for the signed-in Azure user
- start an Arc proxy session to the selected connected cluster
- deploy SQL Server on an Arc-enabled Kubernetes cluster and create a runtime load balancer

Scripts in this folder:

- `generate-service-token.sh`
- `k8s_proxy.sh`
- `sql-on-aks.sh`

## Prerequisites

## Required tools

- `az` (Azure CLI)
- `kubectl`
- `jq` (required by `k8s_proxy.sh`)

Optional but used by one script:

- `pbcopy` on macOS (`generate-service-token.sh` copies token to clipboard)

## Required Azure access

- Access to list and read Arc-enabled Kubernetes resources (`Microsoft.Kubernetes/connectedClusters`)
- Permission to run `az connectedk8s proxy`
- Permission to create Kubernetes resources in the target cluster namespace
- Permission to create `k8s-runtime` load balancer resources (for `sql-on-aks.sh`)

## Cluster expectations

- Target cluster is already connected to Azure Arc
- `kubectl` context resolves to the intended cluster during script execution
- `default` storage class exists for `sql-on-aks.sh` (or update script variable `st_ClassName`)

## Quick Start

1. Start Arc proxy (recommended for local admin operations):

```bash
./k8s_proxy.sh
```

2. In another terminal, validate cluster connectivity:

```bash
kubectl get nodes
```

3. Optionally generate a Kubernetes token for the signed-in Azure user:

```bash
./generate-service-token.sh
```

4. Deploy SQL Server workload:

```bash
./sql-on-aks.sh
```

## Script Details

## 1) k8s_proxy.sh

Purpose:

- discover Arc-enabled Kubernetes clusters
- let you choose one interactively (if no cluster name argument is passed)
- derive resource group and subscription automatically
- start `az connectedk8s proxy`

Usage:

```bash
./k8s_proxy.sh
./k8s_proxy.sh <cluster-name>
./k8s_proxy.sh --help
```

Behavior notes:

- Checks for `az`, `kubectl`, and `jq`
- Installs or upgrades Azure CLI extension `connectedk8s` if missing
- If not logged in, prompts for cloud:
	- `AzureCloud`
	- `AzureUSGovernment`
- Logs output to a timestamped file in the same directory:
	- `k8s_proxy_YYYYMMDD_HHMMSS.log`
- Proxy runs in foreground until Ctrl+C

Output highlights:

- selected cluster name
- inferred resource group
- inferred subscription
- proxy startup messages

## 2) generate-service-token.sh

Purpose:

- generate a Kubernetes token in namespace `default` for the currently signed-in Azure user object ID

Usage:

```bash
./generate-service-token.sh
```

What it does:

- Calls `az ad signed-in-user show --query id`
- Calls `kubectl create token <aad-object-id> -n default`
- Copies token to clipboard with `pbcopy` when available
- Prints token details to terminal

Security note:

- The script prints the full token to stdout at the end.
- Treat terminal logs and shell history as sensitive when using this script.

## 3) sql-on-aks.sh

Purpose:

- deploy SQL Server (`mcr.microsoft.com/mssql/server:2022-latest`) to an Arc-enabled Kubernetes cluster
- create Kubernetes resources for persistence and exposure
- create an Arc runtime load balancer via `az k8s-runtime load-balancer create`

Usage:

```bash
./sql-on-aks.sh
```

Prompts:

- load balancer IP range (default: `x.x.x.x/32` placeholder)
- SQL SA password (hidden input)

Resources created:

- namespace `sql-at-edge`
- secret `mssql-secret`
- statefulset `mssql`
- service `mssql` (type `LoadBalancer`)
- Arc runtime load balancer named `sql-lb`

Operational notes:

- The script currently auto-selects the first Arc cluster returned by `az connectedk8s list`.
- It expects storage class `default`.
- It waits for pod readiness for up to 300 seconds.
- It prints a final configuration summary, including the SA password.

Security note:

- The script outputs the raw SA password in the final summary.
- Avoid running in shared terminals or persisted logs without sanitization.

## Expected Workflow

Recommended order for most scenarios:

1. Run `k8s_proxy.sh` and keep it open.
2. Use a second terminal for `kubectl` commands.
3. Optionally run `generate-service-token.sh` if you need an auth token.
4. Run `sql-on-aks.sh` to deploy SQL workload and Arc load balancer.

## Troubleshooting

## No clusters found

Check:

- Azure login context: `az account show`
- Arc extension present: `az extension list --query "[?name=='connectedk8s']"`
- Connected clusters list: `az connectedk8s list -o table`

## Proxy command fails

Check:

- cluster name and resource group are correct
- account has permissions for Arc proxy operations
- required network access to Arc endpoints

## SQL deployment fails on StorageClass

Check available classes:

```bash
kubectl get storageclass
```

If needed, update `st_ClassName` in `sql-on-aks.sh`.

## SQL pod does not become ready

Check:

```bash
kubectl get pods -n sql-at-edge
kubectl describe pod -n sql-at-edge -l app=mssql-edge
kubectl logs -n sql-at-edge statefulset/mssql
```

Common causes:

- weak or invalid SA password
- PVC or storage provisioning issues
- image pull or node resource pressure

## Load balancer creation fails

Check:

- `az k8s-runtime` commands are available for your environment
- cluster resource URI resolves:
	- `az connectedk8s show -n <cluster> -g <rg> --query id -o tsv`
- selected IP range is valid for your network design

## Script Safety Notes

- These scripts are interactive and intended for operator-driven runs.
- They are not idempotent automation pipelines.
- Some values are printed to terminal that should be handled as secrets.

Before production use, consider hardening:

- remove secret/token echo statements
- add explicit namespace existence checks
- make cluster selection deterministic in `sql-on-aks.sh`
- externalize configurable values to environment variables or arguments
