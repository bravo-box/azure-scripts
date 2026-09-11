#!/bin/bash

################################################################################
# Azure Arc-Enabled Kubernetes Flux GitOps Configuration Script
#
# This script creates a Flux v2 GitOps configuration on an Azure Arc-enabled
# Kubernetes cluster using Azure CLI. It will install the Flux cluster
# extension if needed, then create a k8s-configuration flux resource that
# points at your Git repository.
#
# Prerequisites:
#   - Azure CLI installed
#   - kubectl installed and configured
#   - jq installed
#   - Azure subscription access
#   - Arc extension for Azure CLI (connectedk8s)
#
# Usage: ./create-gitops-config.sh [cluster-name] [options]
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/create-gitops-config_$(date +%Y%m%d_%H%M%S).log"

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

REPO_URL=""
BRANCH="main"
KUSTOMIZATION_PATH=""
CONFIG_NAME="cluster-config"
NAMESPACE="flux-system"
SCOPE="namespace"
KUSTOMIZATION_NAME="apps"
SYNC_INTERVAL="10m"
RETRY_INTERVAL="10m"
PRUNE="true"
AUTH_TYPE="none"
HTTPS_USER=""
HTTPS_TOKEN=""
SSH_KEY_FILE=""
KNOWN_HOSTS_FILE=""

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
    --repo-url URL            Git repository URL (https:// or ssh://)
    --branch NAME              Git branch to sync (default: main)
    --path PATH                Path within the repo to sync (default / blank is root directory)
    --config-name NAME         Flux configuration name (default: cluster-config)
    --namespace NAME            Namespace for the Flux configuration (default: flux-system)
    --scope SCOPE               Configuration scope: cluster or namespace (default: namespace)
    --kustomization-name NAME   Kustomization name (default: apps)
    --interval DURATION          Sync interval, e.g. 1m, 5m (default: 10m)
    --retry-interval DURATION    Retry interval, e.g. 1m, 5m (default: 1m)
    --prune true|false           Prune resources removed from Git (default: true)
    --auth none|https|ssh        Repository auth type (default: none)
    --https-user USER            Username for HTTPS auth
    --https-token TOKEN           Password/PAT for HTTPS auth
    --ssh-key-file PATH           Path to SSH private key file for SSH auth
    --known-hosts-file PATH       Path to known_hosts file for SSH auth
    -h, --help                    Show this help message

EXAMPLES:
    ./create-gitops-config.sh
    ./create-gitops-config.sh myCluster --repo-url https://github.com/org/repo --branch main --path ./clusters/prod

FEATURES:
    - Automatically detects subscription and resource group from cluster
    - Installs the Microsoft.Flux cluster extension if not already present
    - Interactive prompts for any values not supplied as options
    - Full logging for troubleshooting

EOF
}

parse_args() {
    # First positional argument (if not an option) is the cluster name
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
            --repo-url) REPO_URL="$2"; shift 2 ;;
            --branch) BRANCH="$2"; shift 2 ;;
            --path) KUSTOMIZATION_PATH="$2"; shift 2 ;;
            --config-name) CONFIG_NAME="$2"; shift 2 ;;
            --namespace) NAMESPACE="$2"; shift 2 ;;
            --scope) SCOPE="$2"; shift 2 ;;
            --kustomization-name) KUSTOMIZATION_NAME="$2"; shift 2 ;;
            --interval) SYNC_INTERVAL="$2"; shift 2 ;;
            --retry-interval) RETRY_INTERVAL="$2"; shift 2 ;;
            --prune) PRUNE="$2"; shift 2 ;;
            --auth) AUTH_TYPE="$2"; shift 2 ;;
            --https-user) HTTPS_USER="$2"; shift 2 ;;
            --https-token) HTTPS_TOKEN="$2"; shift 2 ;;
            --ssh-key-file) SSH_KEY_FILE="$2"; shift 2 ;;
            --known-hosts-file) KNOWN_HOSTS_FILE="$2"; shift 2 ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
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
    if ! az extension list -o json 2>/dev/null | jq -e '.[] | select(.name=="connectedk8s")' &> /dev/null; then
        log_info "connectedk8s extension not found, installing..."
        az extension add --name connectedk8s --upgrade -y
    fi
    log_success "Arc connectedk8s extension available"

    # Check Azure CLI k8s-configuration extension (provides `az k8s-configuration flux`)
    if ! az extension list -o json 2>/dev/null | jq -e '.[] | select(.name=="k8s-configuration")' &> /dev/null; then
        log_info "k8s-configuration extension not found, installing..."
        az extension add --name k8s-configuration --upgrade -y
    fi
    log_success "Arc k8s-configuration extension available"

    # Check Azure CLI k8s-extension extension (manages cluster extensions like microsoft.flux)
    if ! az extension list -o json 2>/dev/null | jq -e '.[] | select(.name=="k8s-extension")' &> /dev/null; then
        log_info "k8s-extension extension not found, installing..."
        az extension add --name k8s-extension --upgrade -y
    fi
    log_success "Arc k8s-extension extension available"
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

    log_success "Cluster: $CLUSTER_NAME"
    log_success "Resource Group: $RESOURCE_GROUP"
    log_success "Subscription: $SUBSCRIPTION"
}

prompt_gitops_settings() {
    log_info "Collecting GitOps configuration settings..."
    echo ""

    if [[ -z "$REPO_URL" ]]; then
        while [[ -z "$REPO_URL" ]]; do
            read -p "Git repository URL (https:// or ssh://): " REPO_URL
        done
    fi

    read -p "Branch to sync [$BRANCH]: " input; BRANCH="${input:-$BRANCH}"
    read -p "Path within repo to sync [$KUSTOMIZATION_PATH]: " input; KUSTOMIZATION_PATH="${input:-$KUSTOMIZATION_PATH}"
    read -p "Flux configuration name [$CONFIG_NAME]: " input; CONFIG_NAME="${input:-$CONFIG_NAME}"
    read -p "Namespace for configuration [$NAMESPACE]: " input; NAMESPACE="${input:-$NAMESPACE}"

    while true; do
        read -p "Scope, cluster or namespace [$SCOPE]: " input
        input="${input:-$SCOPE}"
        if [[ "$input" == "cluster" ]] || [[ "$input" == "namespace" ]]; then
            SCOPE="$input"
            break
        fi
        log_warning "Scope must be 'cluster' or 'namespace'"
    done

    read -p "Kustomization name [$KUSTOMIZATION_NAME]: " input; KUSTOMIZATION_NAME="${input:-$KUSTOMIZATION_NAME}"
    read -p "Sync interval [$SYNC_INTERVAL]: " input; SYNC_INTERVAL="${input:-$SYNC_INTERVAL}"
    read -p "Retry interval [$RETRY_INTERVAL]: " input; RETRY_INTERVAL="${input:-$RETRY_INTERVAL}"

    while true; do
        read -p "Prune resources removed from Git, true or false [$PRUNE]: " input
        input="${input:-$PRUNE}"
        if [[ "$input" == "true" ]] || [[ "$input" == "false" ]]; then
            PRUNE="$input"
            break
        fi
        log_warning "Prune must be 'true' or 'false'"
    done

    echo ""
    log_info "Select repository authentication method:"
    echo "  1) None (public repository)"
    echo "  2) HTTPS (username + password/PAT)"
    echo "  3) SSH (private key)"
    echo ""

    local auth_choice
    while true; do
        read -p "Select authentication method (1-3): " auth_choice
        case $auth_choice in
            1) AUTH_TYPE="none"; break ;;
            2)
                AUTH_TYPE="https"
                read -p "HTTPS username: " HTTPS_USER
                read -s -p "HTTPS password or PAT: " HTTPS_TOKEN
                echo ""
                break
                ;;
            3)
                AUTH_TYPE="ssh"
                while [[ -z "$SSH_KEY_FILE" ]] || [[ ! -f "$SSH_KEY_FILE" ]]; do
                    read -p "Path to SSH private key file: " SSH_KEY_FILE
                    [[ -f "$SSH_KEY_FILE" ]] || log_warning "File not found: $SSH_KEY_FILE"
                done
                read -p "Path to known_hosts file (optional, press enter to skip): " KNOWN_HOSTS_FILE
                break
                ;;
            *) log_warning "Invalid selection. Please enter 1, 2, or 3" ;;
        esac
    done
}

review_configuration() {
    local auth_summary="None"
    case "$AUTH_TYPE" in
        https) auth_summary="HTTPS (user: $HTTPS_USER, token: ****)" ;;
        ssh) auth_summary="SSH (key: $SSH_KEY_FILE${KNOWN_HOSTS_FILE:+, known_hosts: $KNOWN_HOSTS_FILE})" ;;
    esac

    echo ""
    log_info "Review GitOps configuration:"
    echo "  Cluster:              $CLUSTER_NAME"
    echo "  Resource Group:       $RESOURCE_GROUP"
    echo "  Subscription:         $SUBSCRIPTION"
    echo "  Repository URL:       $REPO_URL"
    echo "  Branch:               $BRANCH"
    echo "  Path:                 $KUSTOMIZATION_PATH"
    echo "  Configuration Name:   $CONFIG_NAME"
    echo "  Namespace:            $NAMESPACE"
    echo "  Scope:                $SCOPE"
    echo "  Kustomization Name:   $KUSTOMIZATION_NAME"
    echo "  Sync Interval:        $SYNC_INTERVAL"
    echo "  Retry Interval:       $RETRY_INTERVAL"
    echo "  Prune:                $PRUNE"
    echo "  Authentication:       $auth_summary"
    echo ""

    local confirm
    while true; do
        read -p "Proceed with this configuration? (y/n): " confirm
        case "$confirm" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) log_warning "Please enter 'y' or 'n'" ;;
        esac
    done
}

ensure_flux_extension() {
    log_info "Checking for the Microsoft.Flux cluster extension..."

    local existing
    existing=$(az k8s-extension list --cluster-name "$CLUSTER_NAME" --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters -o json 2>/dev/null | jq -e '.[] | select(.extensionType=="microsoft.flux")') || existing=""

    if [[ -n "$existing" ]]; then
        log_success "Microsoft.Flux extension already installed on cluster"
        return
    fi

    log_info "Installing Microsoft.Flux extension on cluster (this can take a few minutes)..."
    az k8s-extension create \
        --cluster-name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters \
        --extension-type microsoft.flux \
        --name flux

    log_success "Microsoft.Flux extension installed"
}

create_flux_configuration() {
    log_info "Creating Flux GitOps configuration '$CONFIG_NAME'..."

    local cmd=(az k8s-configuration flux create
        --cluster-name "$CLUSTER_NAME"
        --resource-group "$RESOURCE_GROUP"
        --cluster-type connectedClusters
        --name "$CONFIG_NAME"
        --namespace "$NAMESPACE"
        --url "$REPO_URL"
        --branch "$BRANCH"
        --scope "$SCOPE"
        --kustomization
            "name=${KUSTOMIZATION_NAME}"
            "path=${KUSTOMIZATION_PATH}"
            "prune=${PRUNE}"
            "sync_interval=${SYNC_INTERVAL}"
            "retry_interval=${RETRY_INTERVAL}"
    )

    case "$AUTH_TYPE" in
        https)
            cmd+=(--https-user "$HTTPS_USER" --https-key "$HTTPS_TOKEN")
            ;;
        ssh)
            cmd+=(--ssh-private-key-file "$SSH_KEY_FILE")
            if [[ -n "$KNOWN_HOSTS_FILE" ]]; then
                cmd+=(--known-hosts-contents-file "$KNOWN_HOSTS_FILE")
            fi
            ;;
        none) ;;
    esac

    "${cmd[@]}"

    log_success "Flux GitOps configuration '$CONFIG_NAME' created"
}

show_status() {
    log_info "Fetching configuration status..."
    az k8s-configuration flux show \
        --cluster-name "$CLUSTER_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --cluster-type connectedClusters \
        --name "$CONFIG_NAME" \
        -o table

    log_info ""
    log_info "To check Flux resources on the cluster directly, run:"
    log_info "  kubectl get gitrepositories,kustomizations -n $NAMESPACE"
}

################################################################################
# Main Execution
################################################################################

main() {
    parse_args "$@"

    log_info "Azure Arc Kubernetes Flux GitOps Configuration Script"
    log_info "======================================================="
    log_info "Log file: $LOG_FILE"
    log_info ""

    check_prerequisites
    login_to_azure

    if [[ -z "$CLUSTER_NAME" ]]; then
        select_cluster_interactively
    fi

    extract_cluster_details

    until prompt_gitops_settings && review_configuration; do
        log_warning "Let's re-enter the configuration."
    done

    ensure_flux_extension
    create_flux_configuration
    show_status
}

main "$@"
