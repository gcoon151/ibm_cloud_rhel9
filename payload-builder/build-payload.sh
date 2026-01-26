#!/bin/bash
#
# PodVM Payload Builder for IBM Cloud
#
# This script builds the PodVM payload container image that contains
# the CoCo components (kata-agent, attestation-agent, etc.)
#
# The payload is built from the cloud-api-adaptor repository and
# pushed to IBM Cloud Container Registry (icr.io)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
PAYLOAD_VERSION="${PAYLOAD_VERSION:-1.10.3}"
ARCH="${ARCH:-x86_64}"
REGISTRY="${REGISTRY:-us.icr.io}"
NAMESPACE="${NAMESPACE:-}"
IMAGE_NAME="${IMAGE_NAME:-podvm-payload}"
FULL_IMAGE_TAG="${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:${PAYLOAD_VERSION}"

# Red Hat Subscription
RHEL_ORG_FILE="${RHEL_ORG_FILE:-}"
RHEL_KEY_FILE="${RHEL_KEY_FILE:-}"

# Build tool (podman or docker)
BUILD_TOOL="${BUILD_TOOL:-podman}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

function warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $*"
}

function error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*"
    exit 1
}

function check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check build tool
    if ! command -v "$BUILD_TOOL" &> /dev/null; then
        error "$BUILD_TOOL not found. Install podman or docker."
    fi
    
    # Check git
    if ! command -v git &> /dev/null; then
        error "git not found. Please install git."
    fi
    
    # Check if submodule is initialized
    if [[ ! -f "$SCRIPT_DIR/cloud-api-adaptor/podvm-payload/Dockerfile" ]]; then
        error "cloud-api-adaptor submodule not initialized. Run: git submodule update --init --recursive"
    fi
    
    # Check subscription files
    if [[ -z "$RHEL_ORG_FILE" ]] || [[ -z "$RHEL_KEY_FILE" ]]; then
        error "Red Hat subscription credentials required. Set RHEL_ORG_FILE and RHEL_KEY_FILE"
    fi
    
    if [[ ! -f "$RHEL_ORG_FILE" ]]; then
        error "RHEL org file not found: $RHEL_ORG_FILE"
    fi
    
    if [[ ! -f "$RHEL_KEY_FILE" ]]; then
        error "RHEL activation key file not found: $RHEL_KEY_FILE"
    fi
    
    # Check IBM Cloud CLI for ICR
    if [[ "$REGISTRY" == *"icr.io"* ]]; then
        if ! command -v ibmcloud &> /dev/null; then
            warn "IBM Cloud CLI not found. You'll need it to push to ICR."
            warn "Install from: https://cloud.ibm.com/docs/cli"
        fi
    fi
    
    log "Prerequisites check passed"
}

function apply_patch() {
    log "Applying Dockerfile patch for subscription-manager..."
    
    cd "$SCRIPT_DIR/cloud-api-adaptor"
    
    # Check if patch is already applied
    if grep -q "mount=type=secret,id=org" podvm-payload/Dockerfile; then
        log "Patch already applied, skipping"
    else
        if patch -p1 < "$SCRIPT_DIR/dockerfile-subscription-manager.patch"; then
            log "Patch applied successfully"
        else
            error "Failed to apply patch"
        fi
    fi
    
    cd "$SCRIPT_DIR"
}

function build_payload() {
    log "Building PodVM payload image..."
    log "Version: $PAYLOAD_VERSION"
    log "Architecture: $ARCH"
    log "Image: $FULL_IMAGE_TAG"
    
    cd "$SCRIPT_DIR/cloud-api-adaptor"
    
    # Build command
    local build_cmd=(
        "$BUILD_TOOL" build
        -t "$FULL_IMAGE_TAG"
        -f podvm-payload/Dockerfile
        --secret "id=org,src=$RHEL_ORG_FILE"
        --secret "id=key,src=$RHEL_KEY_FILE"
        --build-arg "ARCH=$ARCH"
        .
    )
    
    log "Running: ${build_cmd[*]}"
    
    if "${build_cmd[@]}"; then
        log "Build completed successfully"
    else
        error "Build failed"
    fi
    
    cd "$SCRIPT_DIR"
}

function login_to_icr() {
    log "Logging in to IBM Cloud Container Registry..."
    
    if ! ibmcloud target &> /dev/null; then
        error "Not logged in to IBM Cloud. Run: ibmcloud login"
    fi
    
    # Get current region
    local region=$(ibmcloud target --output json | jq -r '.region.name' || echo "us-south")
    
    # Login to ICR
    if ibmcloud cr login; then
        log "Logged in to ICR successfully"
    else
        error "Failed to login to ICR"
    fi
    
    # Ensure namespace exists
    if [[ -n "$NAMESPACE" ]]; then
        if ! ibmcloud cr namespace-list | grep -q "^${NAMESPACE}$"; then
            log "Creating ICR namespace: $NAMESPACE"
            ibmcloud cr namespace-add "$NAMESPACE" || error "Failed to create namespace"
        fi
    fi
}

function push_to_registry() {
    log "Pushing image to registry: $FULL_IMAGE_TAG"
    
    # Login to ICR if needed
    if [[ "$REGISTRY" == *"icr.io"* ]]; then
        login_to_icr
    fi
    
    if "$BUILD_TOOL" push "$FULL_IMAGE_TAG"; then
        log "Image pushed successfully"
    else
        error "Failed to push image"
    fi
}

function verify_image() {
    log "Verifying image..."
    
    # Check if image exists locally
    if "$BUILD_TOOL" images | grep -q "$IMAGE_NAME.*$PAYLOAD_VERSION"; then
        log "Image exists locally: $FULL_IMAGE_TAG"
    else
        error "Image not found locally"
    fi
    
    # Get image digest
    local digest=$("$BUILD_TOOL" inspect "$FULL_IMAGE_TAG" --format='{{.Digest}}' 2>/dev/null || echo "")
    if [[ -n "$digest" ]]; then
        log "Image digest: $digest"
        
        # Save digest to file
        echo "$digest" > "$SCRIPT_DIR/payload-digest.txt"
        log "Digest saved to: $SCRIPT_DIR/payload-digest.txt"
    fi
    
    # Get image size
    local size=$("$BUILD_TOOL" inspect "$FULL_IMAGE_TAG" --format='{{.Size}}' 2>/dev/null || echo "0")
    if [[ "$size" -gt 0 ]]; then
        local size_mb=$((size / 1024 / 1024))
        log "Image size: ${size_mb}MB"
    fi
}

function generate_usage_info() {
    log "Generating usage information..."
    
    local digest=$("$BUILD_TOOL" inspect "$FULL_IMAGE_TAG" --format='{{.Digest}}' 2>/dev/null || echo "")
    local full_ref="${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}@${digest}"
    
    cat > "$SCRIPT_DIR/payload-info.txt" << EOF
PodVM Payload Build Information
================================

Image Tag: $FULL_IMAGE_TAG
Image Digest: $digest
Full Reference: $full_ref

Usage in coco-components.sh:
----------------------------
PODVM_BINARY_DEF="$full_ref"
PAUSE_BUNDLE_DEF="$full_ref"

Or with tag:
PODVM_BINARY_DEF="$FULL_IMAGE_TAG"
PAUSE_BUNDLE_DEF="$FULL_IMAGE_TAG"

Pull Command:
-------------
$BUILD_TOOL pull $FULL_IMAGE_TAG

Verify Command:
---------------
$BUILD_TOOL run --rm $FULL_IMAGE_TAG ls -la /artifacts/

Built: $(date)
Version: $PAYLOAD_VERSION
Architecture: $ARCH
EOF
    
    log "Usage information saved to: $SCRIPT_DIR/payload-info.txt"
    cat "$SCRIPT_DIR/payload-info.txt"
}

function cleanup() {
    log "Cleaning up..."
    
    # Optionally remove build artifacts
    if [[ "${CLEANUP_BUILD:-false}" == "true" ]]; then
        log "Removing local image..."
        "$BUILD_TOOL" rmi "$FULL_IMAGE_TAG" || true
    fi
}

function show_help() {
    cat << EOF
PodVM Payload Builder for IBM Cloud

Usage: $0 [OPTIONS]

Options:
  -h, --help              Show this help message
  -v, --version VERSION   Payload version (default: $PAYLOAD_VERSION)
  -a, --arch ARCH         Architecture (default: $ARCH)
  -r, --registry REGISTRY Registry URL (default: $REGISTRY)
  -n, --namespace NS      Registry namespace (required for ICR)
  -i, --image NAME        Image name (default: $IMAGE_NAME)
  -o, --org-file FILE     Red Hat org ID file (required)
  -k, --key-file FILE     Red Hat activation key file (required)
  -t, --tool TOOL         Build tool: podman or docker (default: $BUILD_TOOL)
  --no-push               Build only, don't push to registry
  --cleanup               Remove local image after push

Environment Variables:
  PAYLOAD_VERSION         Payload version
  ARCH                    Architecture (x86_64, aarch64, s390x)
  REGISTRY                Container registry URL
  NAMESPACE               Registry namespace
  IMAGE_NAME              Image name
  RHEL_ORG_FILE           Path to Red Hat org ID file
  RHEL_KEY_FILE           Path to Red Hat activation key file
  BUILD_TOOL              Build tool (podman or docker)

Examples:
  # Build and push to IBM Cloud Container Registry
  $0 --org-file org.txt --key-file key.txt \\
     --registry us.icr.io --namespace my-namespace

  # Build only (no push)
  $0 --org-file org.txt --key-file key.txt --no-push

  # Build specific version
  $0 --version 1.10.4 --org-file org.txt --key-file key.txt

EOF
}

function main() {
    local no_push=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                PAYLOAD_VERSION="$2"
                shift 2
                ;;
            -a|--arch)
                ARCH="$2"
                shift 2
                ;;
            -r|--registry)
                REGISTRY="$2"
                shift 2
                ;;
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -i|--image)
                IMAGE_NAME="$2"
                shift 2
                ;;
            -o|--org-file)
                RHEL_ORG_FILE="$2"
                shift 2
                ;;
            -k|--key-file)
                RHEL_KEY_FILE="$2"
                shift 2
                ;;
            -t|--tool)
                BUILD_TOOL="$2"
                shift 2
                ;;
            --no-push)
                no_push=true
                shift
                ;;
            --cleanup)
                CLEANUP_BUILD=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
    
    # Update full image tag
    FULL_IMAGE_TAG="${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}:${PAYLOAD_VERSION}"
    
    log "=== PodVM Payload Builder ==="
    log "Starting build process..."
    
    check_prerequisites
    apply_patch
    build_payload
    verify_image
    
    if [[ "$no_push" == "false" ]]; then
        push_to_registry
    else
        log "Skipping push (--no-push specified)"
    fi
    
    generate_usage_info
    cleanup
    
    log "=== Build Complete ==="
    log "Image: $FULL_IMAGE_TAG"
    log "See payload-info.txt for usage details"
}

# Run main function
main "$@"

# Made with Bob
