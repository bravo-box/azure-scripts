# SQL Server on Arc-Enabled Kubernetes (Azure Local)

## Overview

This folder contains `sql-on-aks.sh`, an interactive deployment script that provisions SQL Server on an Arc-enabled Kubernetes cluster.

Script path:

- `azure-local/sql-on-aks/sql-on-aks.sh`

The script performs these actions:

1. Detects available Arc-enabled clusters.
2. Picks the first cluster returned by Azure CLI.
3. Prompts for a load balancer IP range and SQL SA password.
4. Verifies required storage class exists.
5. Deploys SQL resources to Kubernetes.
6. Waits for pod readiness.
7. Creates an Arc runtime load balancer.

## Prerequisites

## Tools

- Bash
- Azure CLI (`az`)
- `kubectl`

## Azure CLI extensions and commands

The script depends on these command groups being available:

- `az connectedk8s`
- `az k8s-runtime load-balancer`

Install/verify extensions if needed:

```bash
az extension add --name connectedk8s --upgrade
az extension list -o table
```

Ensure that the arcnetworking extension has been installed:

```
https://learn.microsoft.com/en-us/azure/aks/aksarc/deploy-load-balancer-cli
```

## Access and context

- Authenticated Azure CLI session (`az login`)
- Permission to read Arc-connected cluster resources
- Permission to create Arc runtime load balancer resources
- Active `kubectl` context pointing to the intended cluster

## Kubernetes requirements

- Existing storage class named `default` (or update `st_ClassName` in script)
- Cluster must support `LoadBalancer` services and Arc runtime LB integration

## Usage

Run from repo root:

```bash
./azure-local/sql-on-aks/sql-on-aks.sh
```

Or run from inside the folder:

```bash
cd azure-local/sql-on-aks
./sql-on-aks.sh
```

## Interactive prompts

You will be prompted for:

- Load balancer IP range (defaults to `x.x.x.x/32` placeholder)
- SQL SA password (hidden input)

## What the script deploys

Namespace:

- `sql-at-edge`

Resources:

- Secret: `mssql-secret`
- StatefulSet: `mssql`
- Service (LoadBalancer): `mssql`
- Arc runtime load balancer: `sql-lb`

Container image:

- `mcr.microsoft.com/mssql/server:2022-latest`

Port:

- `1433`

## Kubernetes manifest details (generated inline)

- SQL SA password is base64-encoded into Kubernetes Secret key `SA_PASSWORD`.
- StatefulSet runs with:
	- `runAsUser: 10001`
	- `runAsGroup: 10001`
	- `fsGroup: 10001`
- Storage request is `20Gi` with storage class `default`.
- Service selector uses label `app=mssql-edge`.

## Important behavior notes

- Cluster selection is not interactive in this script; it uses the first cluster from `az connectedk8s list`.
- Script does not check whether namespace already exists before creating it.
- Script prints the SQL SA password in the final summary output.

## Post-deployment verification

```bash
kubectl get ns
kubectl get pods -n sql-at-edge
kubectl get svc -n sql-at-edge
kubectl get statefulset -n sql-at-edge
```

Check SQL pod logs:

```bash
kubectl logs -n sql-at-edge statefulset/mssql
```

## Connectivity

After successful deployment, connect using:

- SQL endpoint: load balancer IP
- SQL port: `1433`
- Username: `sa`
- Password: value entered during script prompt

## Troubleshooting

## No Arc-enabled clusters found

```bash
az connectedk8s list -o table
```

If empty, connect/register the cluster with Arc first.

## StorageClass validation fails

```bash
kubectl get storageclass
```

Either create `default` storage class or change `st_ClassName` in script.

## Pod readiness timeout

```bash
kubectl describe pod -n sql-at-edge -l app=mssql-edge
kubectl logs -n sql-at-edge statefulset/mssql
```

Common causes:

- invalid SA password complexity
- storage provisioning issues
- image pull failures

## Load balancer creation fails

Verify Arc runtime command availability and permissions:

```bash
az k8s-runtime load-balancer -h
```

Validate cluster resource ID:

```bash
az connectedk8s show -n <cluster-name> -g <resource-group> --query id -o tsv
```

## Security considerations

- Do not run this script where terminal output is logged to shared systems.
- The current implementation echoes sensitive information (SA password) in its summary.
- Rotate SQL credentials if exposed.
- Prefer secret input handling and avoid printing credentials in hardened production workflows.

## Suggested hardening improvements

For future updates to `sql-on-aks.sh`:

1. Add explicit cluster selection instead of auto-picking the first cluster.
2. Add namespace existence checks (`kubectl get namespace`).
3. Remove SA password from terminal output.
4. Validate IP range format before creating load balancer.
5. Add optional arguments for namespace, storage class, and image version.
