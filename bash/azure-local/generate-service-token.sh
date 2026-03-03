#!/bin/bash

# Script to generate service token from connected K8s cluster

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

log_info() {
    echo -e "${YELLOW}[*]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[+]${NC} $1"
}

echo "=== Generating Service Token from Connected K8s Cluster ==="
echo ""

# Pull credentials - get AAD entity object ID
log_info "Retrieving AAD entity object ID..."
AAD_ENTITY_OBJECT=$(az ad signed-in-user show --query id -o tsv)

if [ -z "$AAD_ENTITY_OBJECT" ]; then
    echo "[ERROR] Failed to retrieve AAD entity object ID"
    exit 1
fi

log_success "AAD Entity Object ID: $AAD_ENTITY_OBJECT"
echo ""

# Create the service token
log_info "Creating service token..."
TOKEN=$(kubectl create token $AAD_ENTITY_OBJECT -n default)

if [ -z "$TOKEN" ]; then
    echo "[ERROR] Failed to create service token"
    exit 1
fi

# Copy token to clipboard
log_info "Copying token to clipboard..."
echo -n "$TOKEN" | pbcopy

if [ $? -eq 0 ]; then
    log_success "Token copied to clipboard! You can now paste it in your browser."
else
    echo "[WARNING] Failed to copy to clipboard. Token displayed below."
fi

# Log the details
log_success "Service token created successfully"
echo ""
echo "=== Token Details ==="
echo "User ID: $AAD_ENTITY_OBJECT"
echo "Namespace: default"
echo "Token: $TOKEN"
echo ""


