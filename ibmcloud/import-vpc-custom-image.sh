#!/bin/bash
# Import a local disk image into IBM Cloud VPC as a custom image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

alive_probe() {
    while true; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] upload in progress..."
        sleep 30
    done
}

push_qcow2_images_to_cos() {
    set +x
    ibmcloud login -a https://cloud.ibm.com --apikey "$IBM_CLOUD_API_KEY" -r "$IBM_CLOUD_REGION" -g "$COS_BUCKET_RESOURCEGROUP"
    set -x
    ibmcloud cos config endpoint-url --clear
    ibmcloud cos config region --region "$IBM_CLOUD_REGION"
    ibmcloud cos config auth --method IAM
    ibmcloud cos config crn --crn "$COS_BUCKET_CRN" --force
    ibmcloud cos config endpoint-url --url https://s3.us-east.cloud-object-storage.appdomain.cloud
    ibmcloud cos config url-style --style Path
    ibmcloud cos list-objects --bucket "$COS_BUCKET_NAME" --region "$IBM_CLOUD_REGION"
    if ! ibmcloud cos head-object --bucket "$COS_BUCKET_NAME" --key "$IMAGE_FILE" --region "$IBM_CLOUD_REGION" >/dev/null 2>&1; then
        alive_probe &
        ALIVEPROBPID=$!
        ibmcloud cos upload --bucket "$COS_BUCKET_NAME" --key "$IMAGE_FILE" --file "$IMAGE_PATH" --region "$IBM_CLOUD_REGION"
        set +e
        kill -9 "$ALIVEPROBPID"
        set -e
    fi
    ibmcloud cos list-objects --bucket "$COS_BUCKET_NAME" --region "$IBM_CLOUD_REGION"
}

create_vpc_image_from_cos() {
    local cos_url="$1"

    log_info "Checking for existing image named $IMAGE_NAME..."
    EXISTING_IMAGE_ID=$(ibmcloud is images --output json | jq -r ".[] | select(.name==\"$IMAGE_NAME\") | .id" || true)
    if [ -n "$EXISTING_IMAGE_ID" ] && [ "$EXISTING_IMAGE_ID" != "null" ]; then
        log_warn "Deleting existing image $IMAGE_NAME ($EXISTING_IMAGE_ID)"
        ibmcloud is image-delete "$EXISTING_IMAGE_ID" -f >/dev/null
    fi

    log_info "Creating VPC custom image $IMAGE_NAME from $cos_url..."
    ibmcloud is image-create "$IMAGE_NAME" \
        --file "$cos_url" \
        --os-name "$IBM_CLOUD_OS_NAME" \
        --output json >/tmp/ibmcloud-image-create.json

    log_info "Waiting for image to become available..."
    STATUS=""
    for _ in $(seq 1 60); do
        STATUS=$(ibmcloud is images --output json | jq -r ".[] | select(.name==\"$IMAGE_NAME\") | .status" || true)
        if [ "$STATUS" = "available" ]; then
            break
        fi
        if [ "$STATUS" = "failed" ]; then
            log_error "Image import failed"
            exit 1
        fi
        sleep 10
    done

    if [ "$STATUS" != "available" ]; then
        log_error "Timed out waiting for image to become available"
        exit 1
    fi
}

usage() {
    echo "Usage: $0 <image-path> [image-name]"
    echo ""
    echo "Imports a local qcow2/raw/vhd image into IBM Cloud VPC as a custom image."
    echo ""
    echo "Environment variables:"
    echo "  IBM_CLOUD_REGION                       Optional. Default: us-east"
    echo "  IBM_CLOUD_API_KEY                      Rquired IBM_CLOUD_API_KEY is set"
    echo "  IBM_CLOUD_OS_NAME                      Optional. Default: red-9-amd64"
    echo "  COS_BUCKET_RESOURCEGROUP   Optional. Default:default"
    echo "  COS_BUCKET_CRN             Required for COS upload"
    echo "  COS_BUCKET_NAME            Required for COS upload and import"
    echo ""
    echo "Examples:"
    echo "  $0 ./podvm.qcow2"
    echo "  $0 ./podvm.raw peerpod-rhel9-base"
}

if [ "${1:-}" = "help" ] || [ "${1:-}" = "--help" ] || [ $# -lt 1 ]; then
    usage
    exit 1
fi

IMAGE_PATH=$(realpath "$1")
if [ ! -f "$IMAGE_PATH" ]; then
    log_error "Image file not found: $IMAGE_PATH"
    exit 1
fi

IMAGE_FILE=$(basename "$IMAGE_PATH")
DEFAULT_NAME="$(basename "$IMAGE_FILE" | sed 's/\.[^.]*$//')"
IMAGE_NAME="${2:-$DEFAULT_NAME}"
IBM_CLOUD_REGION="$IBM_CLOUD_REGION:-us-east}"
IBM_CLOUD_OS_NAME="${IBM_CLOUD_OS_NAME:-red-9-amd64}"
COS_BUCKET="${COS_BUCKET_NAME:-}"

if [ -z "$COS_BUCKET" ]; then
    log_error "COS_BUCKET_NAME is required"
    exit 1
fi


if [ -z "${IBM_CLOUD_API_KEY:-}" ]; then
    log_error "IBM_CLOUD_API_KEY is required"
    exit 1
fi

if [ -z "${COS_BUCKET_CRN:-}" ]; then
    log_error "COS_BUCKET_CRN is required"
    exit 1
fi

if ! command -v ibmcloud >/dev/null 2>&1; then
    log_error "ibmcloud CLI is not installed"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is not installed"
    exit 1
fi

log_info "Uploading $IMAGE_FILE to COS bucket $COS_BUCKET..."
push_qcow2_images_to_cos

log_info "Logging into IBM Cloud region $IBM_CLOUD_REGION..."
ibmcloud login --apikey "$IBM_CLOUD_API_KEY" -r "$IBM_CLOUD_REGION" -q >/dev/null

COS_URL="cos://$IBM_CLOUD_REGION/$COS_BUCKET/$IMAGE_FILE"

create_vpc_image_from_cos "$COS_URL"

IMAGE_JSON=$(ibmcloud is image "$IMAGE_NAME" --output json)
IMAGE_ID=$(echo "$IMAGE_JSON" | jq -r '.id')

log_info "Image imported successfully"
echo "Name: $IMAGE_NAME"
echo "ID: $IMAGE_ID"
echo "COS URL: $COS_URL"
echo "$IMAGE_JSON" | jq -r '
    "Status: \(.status)",
    "OS: \(.operating_system.name)",
    "Created: \(.created_at)"
'

echo ""
echo "Use this image as the VSI base image ID: $IMAGE_ID"
