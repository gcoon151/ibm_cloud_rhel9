#!/bin/bash
# Consolidated OpenShift management script
# Handles configuration, deployment, cleanup, and debugging

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_cmd() { echo -e "${BLUE}[CMD]${NC} $1"; }

show_usage() {
    cat << EOF
Usage: $0 <command> [options]

OpenShift Management Commands:

  configure-image <image-id> [namespace]
      Update peer-pods ConfigMap with new VSI image ID
      Also updates test YAML files automatically
      Default namespace: openshift-sandboxed-containers-operator

  deploy-test [config-file]
      Deploy a test pod configuration
      Default: configs/test-podvm-image.yaml

  deploy-edr [--no-proxy]
      Deploy Uptycs EDR pod
      --no-proxy: Use direct connection (recommended)
      Default: Uses proxy configuration

  extract-uptycs [namespace] [output-dir]
      Extract Uptycs binaries and certificates from container
      Creates edr/uptycs-complete.tar.gz for podvm builds
      Default namespace: default
      Default output: edr

  cleanup-pod <pod-name> [namespace]
      Safely cleanup stuck peer-pod by restarting CAA
      Prevents stale CRD issues
      Default namespace: default

  debug-caa [--tail N]
      Show Cloud API Adaptor logs
      --tail N: Show last N lines (default: 50)

  debug-pod <pod-name> [namespace]
      Show pod logs and describe output
      Default namespace: default

  restart-caa [namespace]
      Restart the Cloud API Adaptor daemonset
      Default namespace: openshift-sandboxed-containers-operator

Examples:
  $0 configure-image r014-1a70868e-dd6c-454d-8766-67be36b0121b
  $0 deploy-test
  $0 deploy-edr --no-proxy
  $0 extract-uptycs
  $0 cleanup-pod edr-test default
  $0 debug-caa --tail 100
  $0 debug-pod test-podvm-candidate
  $0 restart-caa

EOF
    exit 1
}

check_oc() {
    if ! command -v oc &> /dev/null; then
        log_error "OpenShift CLI (oc) not found"
        log_error "Install: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html"
        exit 1
    fi
    
    if ! oc whoami &> /dev/null; then
        log_error "Not logged into OpenShift"
        log_error "Run: oc login <cluster-url>"
        exit 1
    fi
}

configure_image() {
    # Parse arguments
    AUTO_CONFIRM=false
    IMAGE_ID=""
    NAMESPACE="openshift-sandboxed-containers-operator"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --yes|-y)
                AUTO_CONFIRM=true
                shift
                ;;
            *)
                if [ -z "$IMAGE_ID" ]; then
                    IMAGE_ID="$1"
                else
                    NAMESPACE="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [ -z "$IMAGE_ID" ]; then
        # Try to read from saved file
        IMAGE_ID_FILE="$HOME/.ibm_cloud_image_id"
        if [ -f "$IMAGE_ID_FILE" ]; then
            IMAGE_ID=$(cat "$IMAGE_ID_FILE")
            log_info "Using image ID from $IMAGE_ID_FILE"
        else
            log_error "No image ID provided"
            echo "Usage: $0 configure-image <image-id> [namespace] [--yes]"
            exit 1
        fi
    fi
    
    check_oc
    
    echo "=========================================="
    echo "  Configure OpenShift Peer-Pods Image"
    echo "=========================================="
    echo ""
    echo "Image ID: $IMAGE_ID"
    echo "Namespace: $NAMESPACE"
    echo ""
    
    # Check namespace exists
    if ! oc get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' not found"
        exit 1
    fi
    
    # Check ConfigMap exists
    if ! oc get configmap peer-pods-cm -n "$NAMESPACE" &> /dev/null; then
        log_error "ConfigMap 'peer-pods-cm' not found"
        exit 1
    fi
    
    log_info "Found peer-pods ConfigMap"
    
    # Show current image ID
    CURRENT_IMAGE_ID=$(oc get configmap peer-pods-cm -n "$NAMESPACE" -o jsonpath='{.data.IBMCLOUD_PODVM_IMAGE_ID}' 2>/dev/null || echo "")
    if [ -n "$CURRENT_IMAGE_ID" ]; then
        log_warn "Current IBMCLOUD_PODVM_IMAGE_ID: $CURRENT_IMAGE_ID"
    fi
    
    echo ""
    if [ "$AUTO_CONFIRM" = false ]; then
        read -p "Update peer-pods ConfigMap? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Cancelled"
            exit 0
        fi
    else
        log_info "Auto-confirming ConfigMap update (--yes flag)"
    fi
    
    # Update ConfigMap
    log_info "Updating peer-pods ConfigMap..."
    oc patch configmap peer-pods-cm -n "$NAMESPACE" \
        --type merge -p "{\"data\":{\"IBMCLOUD_PODVM_IMAGE_ID\":\"$IMAGE_ID\"}}"
    log_info "✓ ConfigMap updated"
    
    # Update test YAML
    log_info "Updating test YAML files..."
    TEST_YAML="$PROJECT_ROOT/configs/test-podvm-image.yaml"
    if [ -f "$TEST_YAML" ]; then
        sed -i '' "s|io.katacontainers.config.hypervisor.image: r014-[a-f0-9-]*|io.katacontainers.config.hypervisor.image: $IMAGE_ID|g" "$TEST_YAML"
        log_info "✓ Updated $TEST_YAML"
    fi
    
    # Save image ID
    echo "$IMAGE_ID" > "$PROJECT_ROOT/.current_image_id"
    log_info "✓ Saved to .current_image_id"
    
    echo ""
    log_info "Configuration complete!"
    echo ""
    log_info "Next steps:"
    echo "  1. Restart CAA: $0 restart-caa"
    echo "  2. Deploy test: $0 deploy-test"
}

deploy_test() {
    CONFIG_FILE="${1:-$PROJECT_ROOT/configs/test-podvm-image.yaml}"
    
    check_oc
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    log_info "Deploying test pod from: $CONFIG_FILE"
    oc apply -f "$CONFIG_FILE"
    
    POD_NAME=$(grep "name:" "$CONFIG_FILE" | head -1 | awk '{print $2}')
    NAMESPACE=$(grep "namespace:" "$CONFIG_FILE" | head -1 | awk '{print $2}')
    
    echo ""
    log_info "Monitor deployment:"
    echo "  oc get pods -n ${NAMESPACE:-default} -w"
    echo ""
    log_info "Check logs:"
    echo "  oc logs -n ${NAMESPACE:-default} $POD_NAME"
}

deploy_edr() {
    USE_PROXY=true
    
    if [ "$1" = "--no-proxy" ]; then
        USE_PROXY=false
    fi
    
    check_oc
    
    if [ "$USE_PROXY" = true ]; then
        CONFIG_FILE="$PROJECT_ROOT/configs/relcandidate1.yaml"
        log_info "Deploying EDR with proxy configuration"
    else
        CONFIG_FILE="$PROJECT_ROOT/configs/relcandidate1-no-proxy.yaml"
        log_info "Deploying EDR with direct connection (no proxy)"
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    oc apply -f "$CONFIG_FILE"
    
    echo ""
    log_info "Monitor deployment:"
    echo "  oc get pods -n default -w"
}

cleanup_pod() {
    POD_NAME="${1}"
    NAMESPACE="${2:-default}"
    CAA_NAMESPACE="openshift-sandboxed-containers-operator"
    
    if [ -z "$POD_NAME" ]; then
        log_error "Pod name required"
        echo "Usage: $0 cleanup-pod <pod-name> [namespace]"
        exit 1
    fi
    
    check_oc
    
    echo "=========================================="
    echo "  Safe Peer-Pod Cleanup"
    echo "=========================================="
    echo ""
    echo "Pod: $POD_NAME"
    echo "Namespace: $NAMESPACE"
    echo ""
    
    # Check if pod exists
    if ! oc get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_info "✓ Pod does not exist"
        exit 0
    fi
    
    POD_STATUS=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    log_info "Current status: $POD_STATUS"
    
    echo ""
    log_warn "This will restart the Cloud API Adaptor daemonset"
    log_warn "This is the SAFE way to clean up stuck peer-pods"
    echo ""
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        exit 0
    fi
    
    echo ""
    log_info "[1/3] Deleting pod..."
    oc delete pod "$POD_NAME" -n "$NAMESPACE" --timeout=30s || echo "  (timeout expected)"
    
    echo ""
    log_info "[2/3] Restarting CAA daemonset..."
    oc rollout restart daemonset/osc-caa-ds -n "$CAA_NAMESPACE"
    
    echo ""
    log_info "[3/3] Waiting for rollout..."
    oc rollout status daemonset/osc-caa-ds -n "$CAA_NAMESPACE" --timeout=5m
    
    echo ""
    log_info "✓ Cleanup complete"
}

debug_caa() {
    TAIL_LINES=50
    
    if [ "$1" = "--tail" ]; then
        TAIL_LINES="${2:-50}"
    fi
    
    check_oc
    
    CAA_NAMESPACE="openshift-sandboxed-containers-operator"
    
    log_info "Cloud API Adaptor logs (last $TAIL_LINES lines):"
    echo ""
    oc logs -n "$CAA_NAMESPACE" -l app=cloud-api-adaptor --tail="$TAIL_LINES"
}

debug_pod() {
    POD_NAME="${1}"
    NAMESPACE="${2:-default}"
    
    if [ -z "$POD_NAME" ]; then
        log_error "Pod name required"
        echo "Usage: $0 debug-pod <pod-name> [namespace]"
        exit 1
    fi
    
    check_oc
    
    echo "=========================================="
    echo "  Pod Debug Info: $POD_NAME"
    echo "=========================================="
    echo ""
    
    log_info "Pod Status:"
    oc get pod "$POD_NAME" -n "$NAMESPACE"
    
    echo ""
    log_info "Pod Description:"
    oc describe pod "$POD_NAME" -n "$NAMESPACE"
    
    echo ""
    log_info "Pod Logs:"
    oc logs "$POD_NAME" -n "$NAMESPACE" --tail=50 || log_warn "Could not get logs"
}

restart_caa() {
    NAMESPACE="${1:-openshift-sandboxed-containers-operator}"
    
    check_oc
    
    log_info "Restarting Cloud API Adaptor daemonset..."
    oc rollout restart daemonset/osc-caa-ds -n "$NAMESPACE"
    
    echo ""
    log_info "Waiting for rollout..."
    oc rollout status daemonset/osc-caa-ds -n "$NAMESPACE" --timeout=5m
    
    echo ""
    log_info "✓ CAA restarted successfully"
}

extract_uptycs() {
    NAMESPACE="${1:-default}"
    OUTPUT_DIR="${2:-edr}"
    
    check_oc
    
    log_info "=== Uptycs Payload Extraction ==="
    log_info "Namespace: $NAMESPACE"
    log_info "Output: $OUTPUT_DIR"
    echo ""
    
    # Deploy extractor pod if not exists
    POD_NAME="uptycs-extractor"
    if ! oc get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
        log_info "Deploying extractor pod..."
        oc apply -f "$PROJECT_ROOT/configs/extract-uptycs-pod.yaml" -n "$NAMESPACE"
        
        log_info "Waiting for pod to start..."
        oc wait --for=condition=Ready pod/"$POD_NAME" -n "$NAMESPACE" --timeout=120s
        log_info "✓ Pod ready"
    else
        POD_STATUS=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
        if [ "$POD_STATUS" != "Running" ]; then
            log_error "Pod exists but is not running (status: $POD_STATUS)"
            log_info "Delete and retry: oc delete pod $POD_NAME -n $NAMESPACE"
            exit 1
        fi
        log_info "✓ Using existing pod"
    fi
    echo ""
    
    # Create output directories
    mkdir -p "$OUTPUT_DIR/uptycs-package/bin"
    mkdir -p "$OUTPUT_DIR/uptycs-package/etc"
    
    # Extract binaries
    log_info "Extracting Uptycs binaries..."
    BINARIES=("osqueryd" "uptycs-protect" "uptycs-nft" "bpf_progs.o" "uptycs_audit_conf.sh")
    
    for binary in "${BINARIES[@]}"; do
        if oc exec "$POD_NAME" -n "$NAMESPACE" -- test -f "/usr/bin/$binary" 2>/dev/null; then
            oc cp "$NAMESPACE/$POD_NAME:/usr/bin/$binary" "$OUTPUT_DIR/uptycs-package/bin/$binary"
            log_info "  ✓ Extracted $binary"
        else
            log_warn "  ⚠ Not found: $binary"
        fi
    done
    echo ""
    
    # Extract certificates
    log_info "Extracting certificates..."
    if oc exec "$POD_NAME" -n "$NAMESPACE" -- test -f "/etc/uptycs/ca.crt" 2>/dev/null; then
        oc cp "$NAMESPACE/$POD_NAME:/etc/uptycs/ca.crt" "$OUTPUT_DIR/uptycs-package/etc/ca.crt"
        log_info "  ✓ Extracted ca.crt"
    else
        log_warn "  ⚠ ca.crt not found"
    fi
    echo ""
    
    # Get version information from osqueryd
    log_info "Getting version information..."
    UPTYCS_FULL_VERSION=$(oc exec "$POD_NAME" -n "$NAMESPACE" -- /usr/bin/osqueryd --version 2>/dev/null | head -1 || echo "unknown")
    # Extract just the version number (e.g., "5.18.1.18-Uptycs-Protect" from "osqueryd version 5.18.1.18-Uptycs-Protect")
    UPTYCS_VERSION=$(echo "$UPTYCS_FULL_VERSION" | sed 's/osqueryd version //' | sed 's/-Uptycs-Protect//')
    
    # Get container image hash (last 8 chars of the hash in the image tag)
    CONTAINER_HASH="a7555d3b"  # From: us.icr.io/armada-csutil/uptycs-osquery:20260122-a7555d3b9aac00a50e4bcfb92e25eeffd57a7ad8
    
    EXTRACT_DATE=$(date +%Y%m%d)
    log_info "  Version: $UPTYCS_VERSION"
    log_info "  Container hash: $CONTAINER_HASH"
    log_info "  Extract date: $EXTRACT_DATE"
    
    # Create version file
    cat > "$OUTPUT_DIR/uptycs-package/VERSION" << EOF
Uptycs EDR Package
Version: $UPTYCS_FULL_VERSION
Short Version: $UPTYCS_VERSION
Container Hash: $CONTAINER_HASH
Extracted: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Source Image: us.icr.io/armada-csutil/uptycs-osquery:20260122-a7555d3b9aac00a50e4bcfb92e25eeffd57a7ad8
Extracted by: $(whoami)@$(hostname)
EOF
    echo ""
    
    # Create tarball with version and hash in filename
    # Format: uptycs-complete-5.18.1.18-a7555d3b-20260505.tar.gz
    TARBALL_NAME="uptycs-complete-${UPTYCS_VERSION}-${CONTAINER_HASH}-${EXTRACT_DATE}.tar.gz"
    log_info "Creating tarball..."
    tar -czf "$OUTPUT_DIR/$TARBALL_NAME" -C "$OUTPUT_DIR/uptycs-package" .
    
    # Create symlink for convenience
    ln -sf "$TARBALL_NAME" "$OUTPUT_DIR/uptycs-complete.tar.gz"
    
    TARBALL_SIZE=$(ls -lh "$OUTPUT_DIR/$TARBALL_NAME" | awk '{print $5}')
    log_info "✓ Created $OUTPUT_DIR/$TARBALL_NAME ($TARBALL_SIZE)"
    log_info "✓ Symlink: $OUTPUT_DIR/uptycs-complete.tar.gz -> $TARBALL_NAME"
    echo ""
    
    log_info "=== Extraction Complete ==="
    log_info "Files ready at: $OUTPUT_DIR/$TARBALL_NAME"
    log_info "Package contents:"
    tar -tzf "$OUTPUT_DIR/$TARBALL_NAME" | head -20
}

# Main command dispatcher
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    configure-image)
        configure_image "$@"
        ;;
    deploy-test)
        deploy_test "$@"
        ;;
    deploy-edr)
        deploy_edr "$@"
        ;;
    extract-uptycs)
        extract_uptycs "$@"
        ;;
    cleanup-pod)
        cleanup_pod "$@"
        ;;
    debug-caa)
        debug_caa "$@"
        ;;
    debug-pod)
        debug_pod "$@"
        ;;
    restart-caa)
        restart_caa "$@"
        ;;
    help|--help|-h|"")
        show_usage
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        echo ""
        show_usage
        ;;
esac

# Made with Bob