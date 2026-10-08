#!/bin/bash

################################################################################
# Azure Arc-Enabled Kubernetes Entra ID Service Account Configuration Script
#
# Creates a Kubernetes ServiceAccount whose name matches a Microsoft Entra ID
# object ID (a user, group, or service principal), and binds it to a
# ClusterRole/Role so that identity can later obtain a Kubernetes token via
# `kubectl create token <object-id>` (see generate-service-token.sh).
#
# Prerequisites:
#   - Azure CLI installed and logged in
#   - kubectl installed and pointed at the target cluster (e.g. via k8s_proxy.sh)
#
# Usage: ./config-service-account.sh [OPTIONS]
################################################################################

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/config-service-account_$(date +%Y%m%d_%H%M%S).log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
OBJECT_ID=""
UPN=""
SP_APP_ID=""
NAMESPACE="default"
CLUSTER_ROLE="cluster-admin"
BINDING_SCOPE="cluster"

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
Usage: $0 [OPTIONS]

OPTIONS:
    --object-id ID          Entra ID object ID to align the service account to (default: signed-in user)
    --upn UPN                Resolve object ID from an Entra ID user principal name / email
    --sp-app-id APP_ID       Resolve object ID from an Entra ID service principal app ID
    --namespace NAME          Namespace to create the ServiceAccount in (default: default)
    --cluster-role NAME        ClusterRole to bind (default: cluster-admin)
    --scope cluster|namespace   Binding scope: ClusterRoleBinding or RoleBinding (default: cluster)
    -h, --help                  Show this help message

EXAMPLES:
    ./config-service-account.sh
    ./config-service-account.sh --upn jane.doe@contoso.com --cluster-role edit --scope namespace
    ./config-service-account.sh --sp-app-id 11111111-2222-3333-4444-555555555555 --namespace automation

NOTES:
    - Only one of --object-id, --upn, or --sp-app-id may be used; without any of them the
      currently signed-in Azure user is used.
    - kubectl must already be pointed at the target cluster (run k8s_proxy.sh first).
    - After this script completes, run generate-service-token.sh to obtain a token for the identity.

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --object-id) OBJECT_ID="$2"; shift 2 ;;
            --upn) UPN="$2"; shift 2 ;;
            --sp-app-id) SP_APP_ID="$2"; shift 2 ;;
            --namespace) NAMESPACE="$2"; shift 2 ;;
            --cluster-role) CLUSTER_ROLE="$2"; shift 2 ;;
            --scope) BINDING_SCOPE="$2"; shift 2 ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    local identity_opts=0
    [[ -n "$OBJECT_ID" ]] && identity_opts=$((identity_opts + 1))
    [[ -n "$UPN" ]] && identity_opts=$((identity_opts + 1))
    [[ -n "$SP_APP_ID" ]] && identity_opts=$((identity_opts + 1))
    if [[ $identity_opts -gt 1 ]]; then
        log_error "Only one of --object-id, --upn, or --sp-app-id may be specified"
        exit 1
    fi

    if [[ "$BINDING_SCOPE" != "cluster" ]] && [[ "$BINDING_SCOPE" != "namespace" ]]; then
        log_error "--scope must be 'cluster' or 'namespace'"
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

    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install it first."
        exit 1
    fi
    log_success "kubectl found: $(kubectl version --client --short 2>/dev/null || echo 'installed')"

    if ! az extension list -o json 2>/dev/null | grep -q "connectedk8s"; then
        log_info "Arc extension not found, installing..."
        az extension add --name connectedk8s --upgrade -y
    fi
    log_success "Arc connectedk8s extension available"

    if ! az account show &> /dev/null; then
        log_error "Not logged in to Azure. Run 'az login' first."
        exit 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "kubectl cannot reach a cluster. Start k8s_proxy.sh and point kubectl at the target cluster first."
        exit 1
    fi
    log_success "kubectl has an active cluster connection"
}

resolve_object_id() {
    if [[ -n "$OBJECT_ID" ]]; then
        log_success "Using provided object ID: $OBJECT_ID"
        return
    fi

    if [[ -n "$UPN" ]]; then
        log_info "Resolving object ID for user: $UPN"
        OBJECT_ID=$(az ad user show --id "$UPN" --query id -o tsv)
        if [[ -z "$OBJECT_ID" ]]; then
            log_error "Failed to resolve object ID for user: $UPN"
            exit 1
        fi
        log_success "Resolved object ID: $OBJECT_ID"
        return
    fi

    if [[ -n "$SP_APP_ID" ]]; then
        log_info "Resolving object ID for service principal app ID: $SP_APP_ID"
        OBJECT_ID=$(az ad sp show --id "$SP_APP_ID" --query id -o tsv)
        if [[ -z "$OBJECT_ID" ]]; then
            log_error "Failed to resolve object ID for service principal: $SP_APP_ID"
            exit 1
        fi
        log_success "Resolved object ID: $OBJECT_ID"
        return
    fi

    log_info "No identity specified, using signed-in Azure user..."
    OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)
    if [[ -z "$OBJECT_ID" ]]; then
        log_error "Failed to retrieve signed-in user's object ID"
        exit 1
    fi
    log_success "Signed-in user object ID: $OBJECT_ID"
}

create_namespace_if_missing() {
    if kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_success "Namespace '$NAMESPACE' already exists"
    else
        log_info "Creating namespace '$NAMESPACE'..."
        kubectl create namespace "$NAMESPACE"
        log_success "Namespace '$NAMESPACE' created"
    fi
}

create_service_account() {
    log_info "Creating ServiceAccount '$OBJECT_ID' in namespace '$NAMESPACE'..."
    kubectl create serviceaccount "$OBJECT_ID" -n "$NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    log_success "ServiceAccount '$OBJECT_ID' ready"
}

create_role_binding() {
    local binding_name="entra-${OBJECT_ID}-${CLUSTER_ROLE}"

    if [[ "$BINDING_SCOPE" == "cluster" ]]; then
        log_info "Creating ClusterRoleBinding '$binding_name' -> ClusterRole '$CLUSTER_ROLE'..."
        kubectl create clusterrolebinding "$binding_name" \
            --clusterrole="$CLUSTER_ROLE" \
            --serviceaccount="${NAMESPACE}:${OBJECT_ID}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_success "ClusterRoleBinding '$binding_name' ready"
    else
        log_info "Creating RoleBinding '$binding_name' -> ClusterRole '$CLUSTER_ROLE' in namespace '$NAMESPACE'..."
        kubectl create rolebinding "$binding_name" -n "$NAMESPACE" \
            --clusterrole="$CLUSTER_ROLE" \
            --serviceaccount="${NAMESPACE}:${OBJECT_ID}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log_success "RoleBinding '$binding_name' ready"
    fi
}

print_summary() {
    echo ""
    echo "=== Service Account Configuration Summary ==="
    echo "Entra ID Object ID: $OBJECT_ID"
    echo "Namespace:          $NAMESPACE"
    echo "ClusterRole:        $CLUSTER_ROLE"
    echo "Binding scope:      $BINDING_SCOPE"
    echo ""
    log_success "Next step: run ./generate-service-token.sh to obtain a token for this identity"
}

################################################################################
# Main
################################################################################

main() {
    parse_args "$@"
    check_prerequisites
    resolve_object_id
    create_namespace_if_missing
    create_service_account
    create_role_binding
    print_summary
}

main "$@"
