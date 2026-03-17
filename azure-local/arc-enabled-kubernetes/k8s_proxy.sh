#!/bin/bash

################################################################################
# Azure Arc-Enabled Kubernetes Proxy Connection Script
# 
# This script automates the establishment of a proxy connection to an
# Azure Arc-enabled Kubernetes cluster using Azure CLI.
# 
# No complex configuration needed - just login and select your cluster!
#
# Prerequisites:
#   - Azure CLI installed
#   - kubectl installed and configured
#   - Azure subscription access
#   - Arc extension for Azure CLI
#
# Usage: ./k8s_proxy.sh [cluster-name]
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/k8s_proxy_$(date +%Y%m%d_%H%M%S).log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
CLUSTER_NAME="${1:-}"
SUBSCRIPTION=""
RESOURCE_GROUP=""

################################################################################
# Logging Functions
################################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" >&2
}

################################################################################
# Utility Functions
################################################################################

show_usage() {
    cat << EOF
Usage: $0 [CLUSTER_NAME]

ARGUMENTS:
    CLUSTER_NAME      Optional: Name of Arc-enabled cluster. If not provided, you'll select from available clusters.

EXAMPLES:
    ./k8s_proxy.sh
    ./k8s_proxy.sh myCluster

FEATURES:
    - Automatically detects subscription and resource group from cluster
    - No complex configuration needed
    - Interactive cluster selection if not specified
    - Full logging for troubleshooting

EOF
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check Azure CLI
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    log_success "Azure CLI found: $(az --version | head -n1)"

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install it first."
        exit 1
    fi
    log_success "kubectl found: $(kubectl version --client --short 2>/dev/null || echo 'installed')"

    # Check jq for JSON parsing
    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Please install it first."
        log_info "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
        exit 1
    fi
    log_success "jq found for JSON parsing"

    # Check Azure CLI connectedk8s extension
    if ! az extension list -o json 2>/dev/null | grep -q "connectedk8s"; then
        log_info "Arc extension not found, installing..."
        az extension add --name connectedk8s --upgrade -y
    fi
    log_success "Arc connectedk8s extension available"
}

login_to_azure() {
    log_info "Authenticating with Azure..."

    # Check if already logged in
    if ! az account show &> /dev/null; then
        log_info "Not logged in. Starting Azure CLI login..."
        
        # Prompt for cloud environment selection
        echo ""
        log_info "Select cloud environment:"
        echo "  1) AzureCloud"
        echo "  2) AzureUSGovernment"
        echo ""
        
        local cloud_choice
        while true; do
            read -p "Select cloud environment (1-2): " cloud_choice
            case $cloud_choice in
                1) 
                    az cloud set --name AzureCloud &> /dev/null
                    log_success "Set to AzureCloud"
                    break
                    ;;
                2) 
                    az cloud set --name AzureUSGovernment &> /dev/null
                    log_success "Set to AzureUSGovernment"
                    break
                    ;;
                *) 
                    log_warning "Invalid selection. Please enter 1 or 2"
                    ;;
            esac
        done
        
        az login --use-device-code
    fi

    local current_sub=$(az account show --query 'name' -o tsv)
    log_success "Authenticated. Current subscription: $current_sub"
}

fetch_all_arc_clusters() {
    log_info "Fetching all Arc-enabled clusters across subscriptions..."
    
    # Get all clusters with their resource group and subscription info
    local result
    result=$(az connectedk8s list --query '[].{name:name, resourceGroup:resourceGroup, id:id}' -o json 2>/dev/null) || result="[]"
    
    if [[ -z "$result" ]]; then
        result="[]"
    fi
    
    echo "$result"
}

select_cluster_interactively() {
    local clusters_json=$(fetch_all_arc_clusters)
    
    # Check if we got any clusters
    if [[ -z "$clusters_json" ]] || [[ "$clusters_json" == "[]" ]]; then
        log_error "No Arc-enabled clusters found in any subscription"
        exit 1
    fi

    # Parse JSON and get cluster count
    local cluster_count
    cluster_count=$(echo "$clusters_json" | jq 'length' 2>/dev/null) || cluster_count=0
    
    if [[ $cluster_count -le 0 ]]; then
        log_error "No Arc-enabled clusters found"
        exit 1
    fi

    if [[ $cluster_count -eq 1 ]]; then
        # Only one cluster, auto-select
        CLUSTER_NAME=$(echo "$clusters_json" | jq -r '.[0].name')
        log_success "Auto-selected cluster: $CLUSTER_NAME"
        return
    fi

    # Multiple clusters, show menu
    log_info "Available Arc-enabled clusters:"
    echo ""
    
    local count=1
    while IFS= read -r cluster; do
        local name=$(echo "$cluster" | jq -r '.name')
        local rg=$(echo "$cluster" | jq -r '.resourceGroup')
        echo "  $count) $name (Resource Group: $rg)"
        ((count++))
    done < <(echo "$clusters_json" | jq -c '.[]')
    
    echo ""
    
    local choice
    while true; do
        read -p "Select cluster (1-$cluster_count): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= cluster_count)); then
            CLUSTER_NAME=$(echo "$clusters_json" | jq -r ".[$((choice - 1))].name")
            log_success "Selected cluster: $CLUSTER_NAME"
            break
        else
            log_warning "Invalid selection. Please enter a number between 1 and $cluster_count"
        fi
    done
}

extract_cluster_details() {
    log_info "Extracting cluster details..."

    # Query the cluster to get resource group and subscription
    local cluster_info=$(az connectedk8s list --query "[?name=='$CLUSTER_NAME']" -o json 2>/dev/null)
    
    if [[ -z "$cluster_info" ]] || [[ "$cluster_info" == "[]" ]]; then
        log_error "Cluster not found: $CLUSTER_NAME"
        exit 1
    fi

    # Extract resource group
    RESOURCE_GROUP=$(echo "$cluster_info" | jq -r '.[0].resourceGroup')
    
    # Extract subscription ID from the cluster ID
    # ID format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Kubernetes/connectedClusters/{clusterName}
    SUBSCRIPTION=$(echo "$cluster_info" | jq -r '.[0].id' | cut -d'/' -f3)

    log_success "Cluster: $CLUSTER_NAME"
    log_success "Resource Group: $RESOURCE_GROUP"
    log_success "Subscription: $SUBSCRIPTION"
}

establish_proxy_connection() {
    log_info "Establishing proxy connection to Arc-enabled Kubernetes cluster..."
    log_info ""
    log_info "Starting proxy for cluster: $CLUSTER_NAME"
    log_info "Press Ctrl+C to stop the proxy"
    log_info ""
    log_info "To use kubectl with the proxied cluster in another terminal:"
    log_info "  kubectl config use-context <context-name>"
    log_info "  kubectl get nodes"
    log_info ""

    az connectedk8s proxy --name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP"
}

cleanup_on_exit() {
    log_info "Proxy connection closed"
}

################################################################################
# Main Execution
################################################################################

main() {
    # Handle help flag
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show_usage
        exit 0
    fi

    log_info "Azure Arc Kubernetes Proxy Connection Script"
    log_info "=============================================="
    log_info "Log file: $LOG_FILE"
    log_info ""

    # Set up trap for cleanup on exit
    trap cleanup_on_exit EXIT

    # Execute steps
    check_prerequisites
    login_to_azure

    # Select cluster if not provided
    if [[ -z "$CLUSTER_NAME" ]]; then
        select_cluster_interactively
    fi

    # Extract resource group and subscription from cluster
    extract_cluster_details

    # Establish the proxy connection
    establish_proxy_connection
}

# Run main function
main "$@"
