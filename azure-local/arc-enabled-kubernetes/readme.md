# Arc-Enabled Kubernetes Scripts (Bash & PowerShell)

## Overview

This folder contains helper scripts for common Azure Arc-enabled Kubernetes tasks in Azure Local environments:

- create a Kubernetes token for the signed-in Azure user
- start an Arc proxy session to the selected connected cluster
- deploy SQL Server on an Arc-enabled Kubernetes cluster and create a runtime load balancer
- create a Flux v2 GitOps configuration to sync a Git repository to the cluster

Scripts in this folder:

- `generate-service-token.sh` (Bash) or `generate-service-token.ps1` (PowerShell) — choose based on your platform
- `k8s_proxy.sh` (Bash) or `k8s_proxy.ps1` (PowerShell) — choose based on your platform
- `sql-on-aks.sh` (Bash)
- `create-gitops-config.sh` (Bash) or `create-gitops-config.ps1` (PowerShell) — FLUX v2 GitOps configuration

## Prerequisites

## Required tools

**All scripts:**
- `az` (Azure CLI)
- `kubectl`

**Bash scripts:**
- `jq` (required by `k8s_proxy.sh`)

**PowerShell scripts:**
- PowerShell 7.0+ (recommended)

**Optional:**
- `pbcopy` on macOS (bash `generate-service-token.sh` copies token to clipboard)

## Required Azure access

- Access to list and read Arc-enabled Kubernetes resources (`Microsoft.Kubernetes/connectedClusters`)
- Permission to run `az connectedk8s proxy`
- Permission to create Kubernetes resources in the target cluster namespace
- Permission to create `k8s-runtime` load balancer resources (for `sql-on-aks.sh`)
- Permission to create cluster extensions (`Microsoft.KubernetesConfiguration/extensions`) and Flux configurations (`Microsoft.KubernetesConfiguration/fluxConfigurations`) for `create-gitops-config.sh` / `create-gitops-config.ps1`

## Cluster expectations

- Target cluster is already connected to Azure Arc
- `kubectl` context resolves to the intended cluster during script execution
- `default` storage class exists for `sql-on-aks.sh` (or update script variable `st_ClassName`)

## Quick Start

1. Start Arc proxy (recommended for local admin operations):

**Bash:**
```bash
./k8s_proxy.sh
```

**PowerShell:**
```powershell
./k8s_proxy.ps1
```

2. In another terminal, validate cluster connectivity:

```bash
kubectl get nodes
```

3. Optionally generate a Kubernetes token for the signed-in Azure user:

**Bash:**
```bash
./generate-service-token.sh
```

**PowerShell:**
```powershell
./generate-service-token.ps1
```

4. Deploy SQL Server workload:

```bash
./sql-on-aks.sh
```

5. Create a FLUX GitOps configuration to sync a Git repository to the cluster:

**Bash:**
```bash
./create-gitops-config.sh
```

**PowerShell:**
```powershell
./create-gitops-config.ps1
```

## Script Details

## 1) k8s_proxy.sh (Bash) or k8s_proxy.ps1 (PowerShell)

Purpose:

- discover Arc-enabled Kubernetes clusters
- let you choose one interactively (if no cluster name argument is passed)
- derive resource group and subscription automatically
- start `az connectedk8s proxy`

### Bash Version

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

### PowerShell Version

Usage:

```powershell
./k8s_proxy.ps1
./k8s_proxy.ps1 -ClusterName <cluster-name>
./k8s_proxy.ps1 -Help
```

Behavior notes:

- Checks for `az` and `kubectl` availability
- Installs or upgrades Azure CLI extension `connectedk8s` if missing
- If not logged in, prompts for cloud:
	- `AzureCloud`
	- `AzureUSGovernment`
- Logs output to a timestamped file in the same directory:
	- `k8s_proxy_YYYYMMDD_HHMMSS.log`
- Proxy runs in foreground until Ctrl+C (or `Ctrl+A+D` in PowerShell)
- Optional `-ClusterName` parameter for scripting; omit for interactive selection

Output highlights:

- selected cluster name
- inferred resource group
- inferred subscription
- proxy startup messages
- color-coded status messages

## 2) generate-service-token.sh (Bash) or generate-service-token.ps1 (PowerShell)

Purpose:

- generate a Kubernetes token in namespace `default` for the currently signed-in Azure user object ID

### Bash Version

Usage:

```bash
./generate-service-token.sh
```

What it does:

- Calls `az ad signed-in-user show --query id`
- Calls `kubectl create token <aad-object-id> -n default`
- Copies token to clipboard with `pbcopy` on macOS
- Prints token details to terminal

### PowerShell Version

Usage:

```powershell
./generate-service-token.ps1
```

What it does:

- Calls `az ad signed-in-user show --query id`
- Calls `kubectl create token <aad-object-id> -n default`
- Copies token to clipboard (cross-platform):
  - Windows: uses `Set-Clipboard` cmdlet
  - macOS: uses `pbcopy`
  - Linux: attempts `pbcopy` or `xclip`
- Prints token details to terminal with color-coded status messages

Behavior notes:

- Performs error checking on both Azure CLI and kubectl commands
- Provides detailed error messages if operations fail
- Gracefully handles clipboard failures (warns but continues)

### Security Notes

Both versions:

- Print the full token to stdout at the end
- Treat terminal logs and shell history as sensitive when using these scripts
- Consider redirecting output to `/dev/null` after copying to clipboard in production

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

## 4) create-gitops-config.sh (Bash) or create-gitops-config.ps1 (PowerShell)

Purpose:

- create a **FLUX v2 GitOps configuration** (`Microsoft.KubernetesConfiguration/fluxConfigurations`) on an Arc-enabled Kubernetes cluster, so the cluster continuously syncs manifests from a Git repository

What it does:

- discovers/selects an Arc-enabled cluster (or accepts a `cluster-name` argument) and derives resource group/subscription
- installs the required Azure CLI extensions: `connectedk8s`, `k8s-configuration`, `k8s-extension`
- installs the `microsoft.flux` cluster extension if it isn't already present
- prompts (or accepts flags/parameters) for repo URL, branch, path, config name, namespace, scope (`cluster` or `namespace`), kustomization name, sync/retry intervals, and prune
- supports repository authentication: none (public repo), HTTPS (username + password/PAT), or SSH (private key + optional known_hosts)
- shows a review summary of the collected settings and asks for confirmation before creating anything
- runs `az k8s-configuration flux create` and then `az k8s-configuration flux show` to display the resulting status

### Bash Version

Usage:

```bash
./create-gitops-config.sh
./create-gitops-config.sh <cluster-name>
./create-gitops-config.sh <cluster-name> --repo-url https://github.com/org/repo --branch main --path ./clusters/prod
./create-gitops-config.sh --help
```

### PowerShell Version

Usage:

```powershell
./create-gitops-config.ps1
./create-gitops-config.ps1 -ClusterName <cluster-name>
./create-gitops-config.ps1 -ClusterName <cluster-name> -RepoUrl https://github.com/org/repo -Branch main -Path ./clusters/prod
Get-Help ./create-gitops-config.ps1 -Full
```

Behavior notes (both versions):

- Logs output to a timestamped file in the same directory: `create-gitops-config_YYYYMMDD_HHMMSS.log`
- Any GitOps setting not supplied as an option/parameter is collected interactively, with the option value (or default) shown as the prompt default
- The confirmation step loops back to re-collect settings if you decline

Security note:

- The HTTPS password/PAT is read with hidden input (`read -s` / `Read-Host -AsSecureString`) but is passed to `az` in plaintext as required by the CLI; treat shell history and logs accordingly

## Expected Workflow

Recommended order for most scenarios:

1. Run `k8s_proxy.sh` (or `k8s_proxy.ps1` on PowerShell) and keep it open.
2. Use a second terminal for `kubectl` commands.
3. Optionally run `generate-service-token.sh` (or `generate-service-token.ps1` on PowerShell) if you need an auth token.
4. Run `sql-on-aks.sh` to deploy SQL workload and Arc load balancer.
5. Run `create-gitops-config.sh` (or `create-gitops-config.ps1` on PowerShell) to set up FLUX GitOps sync from a Git repository.

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

## FLUX configuration fails

Check:

- the `microsoft.flux` cluster extension installed successfully: `az k8s-extension list --cluster-name <cluster> --resource-group <rg> --cluster-type connectedClusters -o table`
- the repository URL, branch, and path are correct and reachable from the cluster
- credentials (HTTPS user/PAT or SSH private key) are valid and have read access to the repo
- Flux resource status on the cluster: `kubectl get gitrepositories,kustomizations -n <namespace>`
- detailed reconciliation errors: `kubectl describe kustomization <kustomization-name> -n <namespace>`

## Script Safety Notes

- These scripts are interactive and intended for operator-driven runs.
- They are not idempotent automation pipelines.
- Some values are printed to terminal that should be handled as secrets.

Before production use, consider hardening:

- remove secret/token echo statements
- add explicit namespace existence checks
- make cluster selection deterministic in `sql-on-aks.sh`
- externalize configurable values to environment variables or arguments
