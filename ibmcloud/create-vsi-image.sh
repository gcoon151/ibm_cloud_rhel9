#!/bin/bash
# Create IBM Cloud VSI image from COS bucket
# Run this from your Mac laptop after successful QCOW2 build

set -e

# Load .env for COS credentials
if [ -f .env ]; then
    source .env
fi

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Configuration
IBM_CLOUD_REGION="${IBM_CLOUD_REGION:-us-east}"
QCOW2_NAME="${1}"  # e.g., rhel97-2026020204.qcow2
COS_RESOURCE_INSTANCE_ID="${IBM_CLOUD_COS_RESOURCE_INSTANCE_ID}"
REMOTE_HOST="${REMOTE_HOST:-gcoon@192.168.1.196}"

echo "=========================================="
echo "  IBM Cloud VSI Image Creation"
echo "=========================================="
echo "Region: $IBM_CLOUD_REGION"
echo ""

# Auto-detect latest QCOW2 if not provided
if [ -z "$QCOW2_NAME" ]; then
    log_info "No QCOW2 filename provided, finding latest on remote host..."
    QCOW2_NAME=$(ssh "$REMOTE_HOST" "ls -t ~/gits/openshift/cloud-api-adaptor/podvm/qcow2/rhel97-*.qcow2 2>/dev/null | head -1 | xargs basename" || echo "")
    
    if [ -z "$QCOW2_NAME" ]; then
        log_error "No QCOW2 files found on remote host"
        log_error "Path checked: ~/gits/openshift/cloud-api-adaptor/podvm/qcow2/"
        echo ""
        echo "Usage: $0 [qcow2_filename] [image_name]"
        echo "Example: $0 rhel97-2026020204.qcow2 podvm-candidate"
        echo "Or run without arguments to use the latest QCOW2"
        exit 1
    fi
    
    log_info "Found latest: $QCOW2_NAME"
fi

# Extract timestamp from filename for default image name
TIMESTAMP=$(echo "$QCOW2_NAME" | grep -o '[0-9]\{10\}' || date +%Y%m%d)
IMAGE_NAME="${2:-podvm-candidate-$TIMESTAMP}"

echo "QCOW2: $QCOW2_NAME"
echo "Image Name: $IMAGE_NAME"
echo ""

# Determine which API key to use
# For COS access, we need the COS API key from .env
if [ -n "$IBM_CLOUD_COS_API_KEY" ]; then
    IBM_CLOUD_API_KEY="$IBM_CLOUD_COS_API_KEY"
    log_info "Using COS API key from .env"
else
    # Fallback to OpenShift API key
    API_KEY_FILE="$HOME/agent/env-files/apikey"
    if [ ! -f "$API_KEY_FILE" ]; then
        log_error "No API key found. Set IBM_CLOUD_COS_API_KEY in .env or provide $API_KEY_FILE"
        exit 1
    fi
    IBM_CLOUD_API_KEY=$(cat "$API_KEY_FILE")
    log_info "Using API key from $API_KEY_FILE"
fi

# Login to IBM Cloud
log_info "Logging into IBM Cloud..."
if ibmcloud login --apikey "$IBM_CLOUD_API_KEY" -r "$IBM_CLOUD_REGION" -q; then
    log_info "IBM Cloud login successful ✓"
else
    log_error "IBM Cloud login failed"
    exit 1
fi

# Get COS bucket info from upload script on remote host
log_info "Getting COS bucket information from remote host..."
REMOTE_HOST="${REMOTE_HOST:-gcoon@192.168.1.196}"
COS_BUCKET=$(ssh "$REMOTE_HOST" "grep 'BUCKET=' ~/.local/share/libvirt/images/upload_hl_dev_cos_bucket.sh 2>/dev/null | grep -o \"'[^']*'\" | tr -d \"'\" || echo ''")

if [ -z "$COS_BUCKET" ]; then
    log_error "Could not determine COS bucket name from remote host"
    log_error "Please set IBM_CLOUD_COS_BUCKET in .env file"
    exit 1
fi

log_info "COS Bucket: '$COS_BUCKET'"

# Validate COS Resource Instance ID
if [ -z "$COS_RESOURCE_INSTANCE_ID" ]; then
    log_error "IBM_CLOUD_COS_RESOURCE_INSTANCE_ID not set in .env file"
    exit 1
fi

# Construct COS URL - format: cos://region/bucket/object
COS_URL="cos://$IBM_CLOUD_REGION/$COS_BUCKET/$QCOW2_NAME"
log_info "COS URL: $COS_URL"
log_info "COS Resource Instance ID: ${COS_RESOURCE_INSTANCE_ID:0:50}..."

# Check if image already exists
log_info "Checking for existing image..."
EXISTING_IMAGE=$(ibmcloud is images --output json | jq -r ".[] | select(.name==\"$IMAGE_NAME\") | .id" 2>/dev/null || echo "")

if [ -n "$EXISTING_IMAGE" ]; then
    log_warn "Image '$IMAGE_NAME' already exists (ID: $EXISTING_IMAGE)"
    read -p "Delete existing image and recreate? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deleting existing image..."
        ibmcloud is image-delete "$EXISTING_IMAGE" -f
        log_info "Existing image deleted ✓"
    else
        log_info "Using existing image"
        echo ""
        echo "=========================================="
        log_info "Image already exists: $IMAGE_NAME"
        echo "=========================================="
        exit 0
    fi
fi

# Create VSI image from COS
log_info "Creating VSI image from COS..."
echo ""

# Note: The COS resource instance ID is embedded in the COS URL format
# IBM Cloud will use it to access the object in COS
ibmcloud is image-create "$IMAGE_NAME" \
    --file "$COS_URL" \
    --os-name red-9-amd64 \
    --output json

if [ $? -eq 0 ]; then
    echo ""
    log_info "VSI image creation initiated ✓"
    log_info "Image name: $IMAGE_NAME"
    echo ""
    log_info "Checking image status..."
    
    # Wait for image to be available (10 minutes = 60 iterations * 10 seconds)
    for i in {1..60}; do
        STATUS=$(ibmcloud is images --output json | jq -r ".[] | select(.name==\"$IMAGE_NAME\") | .status" 2>/dev/null || echo "")
        if [ "$STATUS" = "available" ]; then
            log_info "Image is now available ✓"
            break
        elif [ "$STATUS" = "failed" ]; then
            log_error "Image creation failed"
            exit 1
        else
            echo "  Status: $STATUS (waiting... $i/60)"
            sleep 10
        fi
    done
    
    # Verify image is available after loop
    if [ "$STATUS" != "available" ]; then
        log_error "Image did not become available within 10 minutes"
        log_error "Final status: $STATUS"
        echo ""
        log_warn "Image may still be processing. To continue when ready:"
        echo ""
        echo "1. Check image status:"
        echo "   ibmcloud is image $IMAGE_NAME"
        echo ""
        echo "2. When status is 'available', resume the build workflow:"
        echo "   ./scripts/resume-after-vsi.sh $IMAGE_NAME"
        echo ""
        echo "   This will:"
        echo "   - Configure OpenShift with the new image"
        echo "   - Restart Cloud API Adaptor"
        echo "   - Deploy and test the pod"
        echo ""
        exit 1
    fi
    
    echo ""
    echo "=========================================="
    log_info "VSI Image Created Successfully!"
    echo "=========================================="
    echo ""
    
    # Get image details
    IMAGE_JSON=$(ibmcloud is image "$IMAGE_NAME" --output json)
    IMAGE_ID=$(echo "$IMAGE_JSON" | jq -r '.id')
    
    log_info "Image details:"
    echo "$IMAGE_JSON" | jq -r '
        "  Name: \(.name)",
        "  ID: \(.id)",
        "  Status: \(.status)",
        "  OS: \(.operating_system.name)",
        "  Created: \(.created_at)"
    '
    
    # Save image ID to file
    IMAGE_ID_FILE="$HOME/.ibm_cloud_image_id"
    echo "$IMAGE_ID" > "$IMAGE_ID_FILE"
    log_info "Image ID saved to: $IMAGE_ID_FILE"
    
    echo ""
    echo "=========================================="
    log_info "Next Steps: Configure OpenShift"
    echo "=========================================="
    echo ""
    echo "To configure this image in OpenShift peer-pods:"
    echo ""
    echo "1. Update the peer-pods ConfigMap:"
    echo "   oc edit configmap peer-pods-cm -n openshift-sandboxed-containers-operator"
    echo ""
    echo "2. Set the image ID in the ConfigMap:"
    echo "   PODVM_IMAGE_ID: \"$IMAGE_ID\""
    echo ""
    echo "3. Or use this command:"
    echo "   oc patch configmap peer-pods-cm -n openshift-sandboxed-containers-operator \\"
    echo "     --type merge -p '{\"data\":{\"PODVM_IMAGE_ID\":\"$IMAGE_ID\"}}'"
    echo ""
    echo "Image ID: $IMAGE_ID"
    echo ""
else
    log_error "VSI image creation failed"
    exit 1
fi

# Made with Bob
