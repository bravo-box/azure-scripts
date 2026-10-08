#!/bin/bash

################################################################################
# Azure Arc-Enabled Kubernetes MetalLB Networking Extension Script
#
# Enables the MetalLB (Arc networking) load balancer extension on an
# Azure Arc-enabled Kubernetes cluster, then optionally creates an initial
# MetalLB load balancer instance (IPAddressPool + L2Advertisement/BGPAdvertisement).
#
# Reference: https://learn.microsoft.com/azure/aks/aksarc/multi-rack/deploy-load-balancer-cli
#
# Prerequisites:
#   - Azure CLI installed
#   - jq installed
#   - Azure subscription access
#   - Arc extension for Azure CLI (connectedk8s)
#
# Usage: ./config-networking-extn.sh [cluster-name] [options]
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/config-networking-extn_$(date +%Y%m%d_%H%M%S).log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
CLUSTER_NAME=""
SUBSCRIPTION=""
RESOURCE_GROUP=""
RESOURCE_URI=""

# Microsoft Entra ID application (first-party app) backing the Arc Kubernetes
# Runtime / MetalLB extension. Can vary by cloud; override with --fpa-app-id.
FPA_APP_ID="087fca6e-4606-4d41-b3f6-5ebdf75b8b4c"
METHOD="auto"

CREATE_LB="false"
LB_NAME="metallb"
IP_RANGE=""
ADVERTISE_MODE="ARP"

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
Usage: $0 [CLUSTER_NAME] [OPTIONS]

ARGUMENTS:
    CLUSTER_NAME              Optional: Name of Arc-enabled cluster. If not provided, you'll select from available clusters.

OPTIONS:
    --method auto|graph|rp      How to enable the extension (default: auto)
                                   graph: use 'az k8s-runtime load-balancer enable' (requires Microsoft Graph Application.Read.All)
                                   rp:    register Microsoft.KubernetesRuntime and use 'az k8s-extension create'
                                   auto:  try graph, fall back to rp
    --fpa-app-id APP_ID          Entra ID app ID of the Arc Kubernetes Runtime extension (default: $FPA_APP_ID)
    --create-load-balancer       Also create a MetalLB load balancer instance after enabling the extension
    --lb-name NAME                Load balancer instance name (default: metallb)
    --ip-range RANGE               IP address range for the load balancer, e.g. 192.168.1.240-192.168.1.250
    --advertise-mode ARP|BGP|Both   MetalLB advertise mode (default: ARP)
    -h, --help                      Show this help message

EXAMPLES:
    ./config-networking-extn.sh
    ./config-networking-extn.sh myCluster --create-load-balancer --ip-range 192.168.1.240-192.168.1.250
    ./config-networking-extn.sh myCluster --method rp

FEATURES:
    - Automatically detects subscription and resource group from cluster
    - Installs/upgrades the k8s-runtime, connectedk8s, and k8s-extension Azure CLI extensions
    - Skips enabling the extension if it's already installed on the cluster
    - Interactive cluster selection if not specified

EOF
}

parse_args() {
    if [[ $# -gt 0 ]] && [[ "$1" != --* ]] && [[ "$1" != "-h" ]]; then
        CLUSTER_NAME="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --method) METHOD="$2"; shift 2 ;;
            --fpa-app-id) FPA_APP_ID="$2"; shift 2 ;;
            --create-load-balancer) CREATE_LB="true"; shift ;;
            --lb-name) LB_NAME="$2"; shift 2 ;;
            --ip-range) IP_RANGE="$2"; shift 2 ;;
            --advertise-mode) ADVERTISE_MODE="$2"; shift 2 ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    if [[ "$METHOD" != "auto" ]] && [[ "$METHOD" != "graph" ]] && [[ "$METHOD" != "rp" ]]; then
        log_error "--method must be 'auto', 'graph', or 'rp'"
        exit 1
    fi

    if [[ "$ADVERTISE_MODE" != "ARP" ]] && [[ "$ADVERTISE_MODE" != "BGP" ]] && [[ "$ADVERTISE_MODE" != "Both" ]]; then
        log_error "--advertise-mode must be 'ARP', 'BGP', or 'Both'"
        exit 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Please install it first."
        exit 1
    fi
    log_success "Azure CLI found: $(az --version | head -n1)"

    if ! command -v jq &> /dev/null; then
        log_error "jq is not installed. Please install it first."
        log_info "Install with: brew install jq (macOS) or apt-get install jq (Linux)"
        exit 1
    fi
    log_success "jq found for JSON parsing"

    if ! az extension list -o json 2>/dev/null | jq -e '.[] | select(.name=="connectedk8s")' &> /dev/null; then
        log_info "connectedk8s extension not found, installing..."
        az extension add --name connectedk8s --upgrade -y
    fi
    log_success "Arc connectedk8s extension available"

    if ! az extension list -o json 2>/dev/null | jq -e '.[] | select(.name=="k8s-extension")' &> /dev/null; then
        log_info "k8s-extension extension not found, installing..."
        az extension add --name k8s-extension --upgrade -y
    fi
    log_success "Arc k8s-extension extension available"

    if ! az extension list -o json 2>/dev/null | jq -e '.[] | select(.name=="k8s-runtime")' &> /dev/null; then
        log_info "k8s-runtime extension not found, installing..."
        az extension add --name k8s-runtime --upgrade -y
    fi
    log_success "Arc k8s-runtime extension available"
}

login_to_azure() {
    log_info "Authenticating with Azure..."

    if ! az account show &> /dev/null; then
        log_info "Not logged in. Starting Azure CLI login..."

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

    local result
    result=$(az connectedk8s list --query '[].{name:name, resourceGroup:resourceGroup, id:id}' -o json 2>/dev/null) || result="[]"

    if [[ -z "$result" ]]; then
        result="[]"
    fi

    echo "$result"
}

select_cluster_interactively() {
    local clusters_json=$(fetch_all_arc_clusters)

    if [[ -z "$clusters_json" ]] || [[ "$clusters_json" == "[]" ]]; then
        log_error "No Arc-enabled clusters found in any subscription"
        exit 1
    fi

    local cluster_count
    cluster_count=$(echo "$clusters_json" | jq 'length' 2>/dev/null) || cluster_count=0

    if [[ $cluster_count -le 0 ]]; then
        log_error "No Arc-enabled clusters found"
        exit 1
    fi

    if [[ $cluster_count -eq 1 ]]; then
        CLUSTER_NAME=$(echo "$clusters_json" | jq -r '.[0].name')
        log_success "Auto-selected cluster: $CLUSTER_NAME"
        return
    fi

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

    local cluster_info=$(az connectedk8s list --query "[?name=='$CLUSTER_NAME']" -o json 2>/dev/null)

    if [[ -z "$cluster_info" ]] || [[ "$cluster_info" == "[]" ]]; then
        log_error "Cluster not found: $CLUSTER_NAME"
        exit 1
    fi

    RESOURCE_GROUP=$(echo "$cluster_info" | jq -r '.[0].resourceGroup')

    # ID format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.Kubernetes/connectedClusters/{clusterName}
    SUBSCRIPTION=$(echo "$cluster_info" | jq -r '.[0].id' | cut -d'/' -f3)
    RESOURCE_URI="subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Kubernetes/connectedClusters/${CLUSTER_NAME}"

    log_success "Cluster: $CLUSTER_NAME"
    log_success "Resource Group: $RESOURCE_GROUP"
    log_success "Subscription: $SUBSCRIPTION"
}

extension_already_enabled() {
    az k8s-extension list --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters -o json 2>/dev/null \
        | jq -e '.[] | select(.extensionType=="microsoft.arcnetworking")' &> /dev/null
}

has_graph_permission() {
    # Probes Application.Read.All by reading the Microsoft Graph service principal
    az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" -o json 2>/dev/null \
        | jq -e 'length > 0' &> /dev/null
}

enable_via_graph() {
    log_info "Enabling MetalLB extension via 'az k8s-runtime load-balancer enable'..."
    az k8s-runtime load-balancer enable --resource-uri "$RESOURCE_URI"
    log_success "MetalLB extension enabled (graph method)"
}

enable_via_resource_provider() {
    log_info "Registering Microsoft.KubernetesRuntime resource provider..."
    az provider register -n Microsoft.KubernetesRuntime

    local state
    state=$(az provider show -n Microsoft.KubernetesRuntime --query registrationState -o tsv 2>/dev/null)
    log_info "Microsoft.KubernetesRuntime registration state: $state"

    log_info "Resolving object ID for Arc Kubernetes Runtime app ($FPA_APP_ID)..."
    local obj_id
    obj_id=$(az ad sp list --filter "appId eq '${FPA_APP_ID}'" --query "[].id" -o tsv)
    if [[ -z "$obj_id" ]]; then
        log_error "Could not resolve service principal object ID for app ID: $FPA_APP_ID"
        log_error "Ask your Azure tenant administrator for the correct Arc Kubernetes Runtime app ID, then re-run with --fpa-app-id"
        exit 1
    fi
    log_success "Resolved k8sRuntimeFpaObjectId: $obj_id"

    log_info "Installing microsoft.arcnetworking extension (this can take a few minutes)..."
    az k8s-extension create \
        --cluster-name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters \
        --extension-type microsoft.arcnetworking \
        --config "k8sRuntimeFpaObjectId=${obj_id}" \
        --name arcnetworking

    log_success "MetalLB extension enabled (resource provider method)"
}

enable_metallb_extension() {
    log_info "Checking for the MetalLB (microsoft.arcnetworking) cluster extension..."

    if extension_already_enabled; then
        log_success "MetalLB extension already installed on cluster"
        return
    fi

    case "$METHOD" in
        graph)
            enable_via_graph
            ;;
        rp)
            enable_via_resource_provider
            ;;
        auto)
            if has_graph_permission; then
                log_info "Microsoft Graph Application.Read.All permission detected, using graph method"
                enable_via_graph
            else
                log_warning "Microsoft Graph Application.Read.All permission not detected, falling back to resource provider method"
                enable_via_resource_provider
            fi
            ;;
    esac
}

prompt_load_balancer_settings() {
    if [[ "$CREATE_LB" != "true" ]]; then
        echo ""
        local create_choice
        read -p "Create a MetalLB load balancer instance now? (y/n): " create_choice
        case "$create_choice" in
            y|Y) CREATE_LB="true" ;;
            *) return ;;
        esac
    fi

    read -p "Load balancer name [$LB_NAME]: " input; LB_NAME="${input:-$LB_NAME}"

    while [[ -z "$IP_RANGE" ]]; do
        read -p "IP address range (e.g. 192.168.1.240-192.168.1.250): " IP_RANGE
    done

    while true; do
        read -p "Advertise mode, ARP/BGP/Both [$ADVERTISE_MODE]: " input
        input="${input:-$ADVERTISE_MODE}"
        if [[ "$input" == "ARP" ]] || [[ "$input" == "BGP" ]] || [[ "$input" == "Both" ]]; then
            ADVERTISE_MODE="$input"
            break
        fi
        log_warning "Advertise mode must be 'ARP', 'BGP', or 'Both'"
    done
}

create_load_balancer() {
    [[ "$CREATE_LB" == "true" ]] || return 0

    log_info "Creating MetalLB load balancer '$LB_NAME' (advertise mode: $ADVERTISE_MODE)..."
    az k8s-runtime load-balancer create \
        --load-balancer-name "$LB_NAME" \
        --resource-uri "$RESOURCE_URI" \
        --addresses "$IP_RANGE" \
        --advertise-mode "$ADVERTISE_MODE"

    log_success "Load balancer '$LB_NAME' created"
}

print_summary() {
    echo ""
    echo "=== MetalLB Networking Extension Summary ==="
    echo "Cluster:          $CLUSTER_NAME"
    echo "Resource Group:   $RESOURCE_GROUP"
    echo "Subscription:     $SUBSCRIPTION"
    if [[ "$CREATE_LB" == "true" ]]; then
        echo "Load Balancer:    $LB_NAME ($IP_RANGE, mode: $ADVERTISE_MODE)"
    else
        echo "Load Balancer:    not created (extension only)"
    fi
    echo ""
    log_success "MetalLB networking extension configuration complete"
}

################################################################################
# Main
################################################################################

main() {
    parse_args "$@"
    check_prerequisites
    login_to_azure

    if [[ -z "$CLUSTER_NAME" ]]; then
        select_cluster_interactively
    fi

    extract_cluster_details
    enable_metallb_extension
    prompt_load_balancer_settings
    create_load_balancer
    print_summary
}

main "$@"
