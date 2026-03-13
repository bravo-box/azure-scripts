#!/bin/bash

# This script sets up SQL Server on Arc-enabled Azure Kubernetes Service (AKS),
# particularly focused on setup for Azure Local.
# It assumes that the AKS cluster is already created and configured with Azure Arc.
# Prerequisites:
# - Azure CLI installed and logged in
# - Azure connectedk8s extension installed
# - kubectl installed
# - Ensure that you have your proxy connection already established before running this script.
#       az connectedk8s proxy -n <cluster-name> -g <resource-group>


fetch_all_arc_clusters() {
  echo "Fetching all Arc-enabled clusters across subscriptions..." >&2
    
    # Get all clusters with their resource group and subscription info
    local result
    result=$(az connectedk8s list --query '[].{name:name, resourceGroup:resourceGroup, id:id}' -o json 2>/dev/null) || result="[]"
    
    if [[ -z "$result" ]]; then
        result="[]"
    fi
    
    echo "$result"
}

  fetch_all_arc_cluster() {
    local result
    result=$(fetch_all_arc_clusters)

    local cluster_name
    cluster_name=$(az connectedk8s list --query "[0].name" -o tsv 2>/dev/null)

    if [[ -z "$cluster_name" || "$cluster_name" == "null" ]]; then
      echo ""
      return 1
    fi

    echo "$cluster_name"
  }

# ================================================
# Variables
# ================================================
CLUSTER_NAME=""
NAMESPACE="sql-at-edge"
SQL_IMAGE="mcr.microsoft.com/mssql/server:2022-latest"
lbname="sql-lb"
ipRange=""
DEFAULT_IP_RANGE="x.x.x.x/32"
SQL_PORT=1433
SQL_PWD=""  # Replace with a strong SA password
app_Label="mssql-edge"
st_ClassName="default"

# ================================================
# CAPTURE VARIABLES FROM USER INPUT
# ================================================

cluster_name=$(fetch_all_arc_cluster)
if [[ -z "$cluster_name" ]]; then
  echo "❌ No Arc-enabled Kubernetes clusters found. Please connect a cluster with 'az connectedk8s connect' and retry."
  exit 1
fi

CLUSTER_NAME="$cluster_name"

read -r -p "Enter load balancer IP range [${DEFAULT_IP_RANGE}]: " ipRange
ipRange=${ipRange:-$DEFAULT_IP_RANGE}

read -s -r -p "Enter SQL SA password: " SQL_PWD
echo

clusterRG=$(az connectedk8s list --query "[?name=='$CLUSTER_NAME'].resourceGroup" -o tsv)
echo "✅ Using AKS Cluster: $CLUSTER_NAME in Resource Group: $clusterRG"
echo "✅ Using IP Range: $ipRange"

# ================================================
# VALIDATE STORAGE CLASS EXISTS
# ================================================

StorageClass=$(kubectl get storageclass $st_ClassName -o jsonpath="{.metadata.name}" 2>/dev/null)
if [[ "$StorageClass" == "$st_ClassName" ]]; then
    echo "✅ StorageClass '$StorageClass' found."
else
    echo "❌ No StorageClass called '$st_ClassName' found in the cluster. Please create the StorageClass before proceeding."
    exit 1
fi

# ================================================
# ENCODE SQL SA PASSWORD - BASE64
# ================================================
ENCODED_SQL_PWD=$(echo -n "$SQL_PWD" | base64)

# ================================================
# Create Namespace
# ================================================
kubectl create namespace $NAMESPACE
echo "✅ Namespace '$NAMESPACE' created."

# ================================================
# Deploy SQL Server on AKS
# ================================================
kubectl apply -n $NAMESPACE -f - <<EOF

apiVersion: v1
kind: Secret
metadata:
  namespace: $NAMESPACE
  name: mssql-secret
type: Opaque
data:
  SA_PASSWORD: $ENCODED_SQL_PWD
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  namespace: $NAMESPACE
  name: mssql-pvc
  labels:
    app: ${app_Label}
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  storageClassName: $st_ClassName
  volumeMode: Filesystem
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  namespace: $NAMESPACE
  name: mssql
  labels:
    app: ${app_Label}
spec:
  serviceName: "mssql"
  replicas: 1
  selector:
    matchLabels:
      app: ${app_Label}
  template:
    metadata:
      labels:
        app: ${app_Label}
    spec:
      securityContext:
        runAsUser: 10001        # SQL Server container user
        fsGroup: 10001          # Ensures PVC is writable by SQL Server
        runAsGroup: 10001
      containers:
        - name: mssql
          image: $SQL_IMAGE
          securityContext:
            allowPrivilegeEscalation: false
          ports:
            - containerPort: 1433
          env:
            - name: ACCEPT_EULA
              value: "Y"
            - name: SA_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mssql-secret
                  key: SA_PASSWORD
          volumeMounts:
            - name: mssql-data
              mountPath: /var/opt/mssql
  volumeClaimTemplates:
    - metadata:
        name: mssql-data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: $st_ClassName
        resources:
          requests:
            storage: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  namespace: $NAMESPACE
  name: mssql
  annotations:
    app: ${app_Label}
  labels:
    app: ${app_Label}
spec:
  type: LoadBalancer
  ports:
    - port: 1433
      targetPort: 1433
  selector:
    app: ${app_Label}
EOF

echo "✅ SQL Server deployment applied."

# ================================================
# Wait for SQL Server Pod to be Ready
# ================================================
echo "... Waiting for SQL Server pod to be ready..."
kubectl wait --namespace $NAMESPACE --for=condition=ready pod -l app=${app_Label} --timeout=300s
echo "✅ SQL Server pod is ready." 

# ================================================
# CREATE LOAD BALANCER
# ================================================
resUri=$(az connectedk8s show -n $CLUSTER_NAME -g $clusterRG --query id -o tsv)
advertiseMode=both
svcSelector="{\"app\":\"$app_Label\"}"

az k8s-runtime load-balancer create --load-balancer-name $lbname --resource-uri $resUri --addresses $ipRange --advertise-mode $advertiseMode --service-selector $svcSelector

echo "✅ Load balancer '$lbname' created."

# ================================================
# FINAL VARIABLE OUTPUTS
# ===============================================

echo "==============================================="
echo "✅ SQL Server on AKS Configuration Summary:"
echo "  >> AKS Cluster Name: $CLUSTER_NAME"
echo "  >> Namespace: $NAMESPACE"
echo "  >> SQL Server Image: $SQL_IMAGE"
echo "  >> Load Balancer Name: $lbname"
echo "  >> SQL Server Port: $SQL_PORT"
echo "  >> SQL Server SA Password: $SQL_PWD"
echo "  >> Service Selector: $svcSelector"
echo "  >> IP Range: $ipRange"
echo "  >> LB Resource URI: $resUri"
echo "  >> To connect to SQL Server, use the Load Balancer IP on port $SQL_PORT"

echo "==============================================="
echo "✅ SQL Server on AKS Setup Complete!"
echo "==============================================="