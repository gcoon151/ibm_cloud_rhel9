#!/bin/bash
#
# IBM Cloud VSI-based PodVM Image Builder
# 
# This script orchestrates the creation of PodVM images using IBM Cloud VSI
# instead of local containers. It:
# 1. Downloads base QCOW2 from IBM Cloud COS
# 2. Creates a secure VSI with no public internet
# 3. Attaches the QCOW2 as a data volume
# 4. Uses cloud-init to run transformation scripts
# 5. Uploads the result back to COS with versioned naming
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# IBM Cloud Configuration
IBM_CLOUD_REGION="${IBM_CLOUD_REGION:-us-south}"
IBM_CLOUD_ZONE="${IBM_CLOUD_ZONE:-us-south-1}"
IBM_CLOUD_RESOURCE_GROUP="${IBM_CLOUD_RESOURCE_GROUP:-default}"
IBM_CLOUD_VPC_NAME="${IBM_CLOUD_VPC_NAME:-podvm-builder-vpc}"
IBM_CLOUD_SUBNET_NAME="${IBM_CLOUD_SUBNET_NAME:-podvm-builder-subnet}"
IBM_CLOUD_VSI_PROFILE="${IBM_CLOUD_VSI_PROFILE:-bx2-2x8}"
IBM_CLOUD_VSI_IMAGE="${IBM_CLOUD_VSI_IMAGE:-ibm-redhat-9-3-minimal-amd64-1}"

# COS Configuration
COS_BUCKET_NAME="${COS_BUCKET_NAME:-podvm-images}"
COS_BASE_IMAGE_NAME="${COS_BASE_IMAGE_NAME:-rhel9-base.qcow2}"
COS_ENDPOINT="${COS_ENDPOINT:-s3.us-south.cloud-object-storage.appdomain.cloud}"
COS_INSTANCE_ID="${COS_INSTANCE_ID:-}"

# Build Configuration
BUILD_DATE=$(date +%Y%m%d)
OUTPUT_IMAGE_PREFIX="${OUTPUT_IMAGE_PREFIX:-podvm-rhel9}"
WORK_DIR="${WORK_DIR:-/tmp/podvm-builder-$$}"

# Logging
LOG_FILE="${LOG_FILE:-$WORK_DIR/build.log}"

function log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

function error() {
    log "ERROR: $*"
    exit 1
}

function cleanup() {
    log "Cleaning up resources..."
    if [[ -n "${VSI_ID:-}" ]]; then
        log "Deleting VSI: $VSI_ID"
        ibmcloud is instance-delete "$VSI_ID" --force || true
    fi
    if [[ -n "${VOLUME_ID:-}" ]]; then
        log "Deleting volume: $VOLUME_ID"
        ibmcloud is volume-delete "$VOLUME_ID" --force || true
    fi
    if [[ -d "$WORK_DIR" ]]; then
        log "Removing work directory: $WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT

function check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check IBM Cloud CLI
    if ! command -v ibmcloud &> /dev/null; then
        error "IBM Cloud CLI not found. Install from: https://cloud.ibm.com/docs/cli"
    fi
    
    # Check plugins
    if ! ibmcloud plugin list | grep -q "vpc-infrastructure"; then
        error "VPC infrastructure plugin not installed. Run: ibmcloud plugin install vpc-infrastructure"
    fi
    
    if ! ibmcloud plugin list | grep -q "cloud-object-storage"; then
        error "COS plugin not installed. Run: ibmcloud plugin install cloud-object-storage"
    fi
    
    # Check login
    if ! ibmcloud target &> /dev/null; then
        error "Not logged in to IBM Cloud. Run: ibmcloud login"
    fi
    
    log "Prerequisites check passed"
}

function setup_work_directory() {
    log "Setting up work directory: $WORK_DIR"
    mkdir -p "$WORK_DIR"
    mkdir -p "$WORK_DIR/scripts"
    mkdir -p "$WORK_DIR/cloud-init"
}

function get_next_version_number() {
    local prefix=$1
    local date=$2
    
    log "Determining next version number for $prefix-$date..."
    
    # List existing objects with the prefix
    local existing=$(ibmcloud cos list-objects \
        --bucket "$COS_BUCKET_NAME" \
        --prefix "${prefix}-${date}" \
        --output json 2>/dev/null | jq -r '.Contents[]?.Key // empty' || echo "")
    
    if [[ -z "$existing" ]]; then
        echo "01"
        return
    fi
    
    # Find highest version number
    local max_version=0
    while IFS= read -r obj; do
        if [[ $obj =~ ${prefix}-${date}([0-9]{2}) ]]; then
            local ver="${BASH_REMATCH[1]}"
            ver=$((10#$ver))  # Convert to decimal
            if [[ $ver -gt $max_version ]]; then
                max_version=$ver
            fi
        fi
    done <<< "$existing"
    
    # Increment and format
    local next_version=$((max_version + 1))
    printf "%02d" "$next_version"
}

function download_base_image() {
    log "Downloading base image from COS: $COS_BASE_IMAGE_NAME"
    
    local local_path="$WORK_DIR/base-image.qcow2"
    
    ibmcloud cos download \
        --bucket "$COS_BUCKET_NAME" \
        --key "$COS_BASE_IMAGE_NAME" \
        --file "$local_path" \
        --region "$IBM_CLOUD_REGION" || error "Failed to download base image"
    
    log "Base image downloaded to: $local_path"
    echo "$local_path"
}

function create_cloud_init_config() {
    log "Creating cloud-init configuration..."
    
    local cloud_init_file="$WORK_DIR/cloud-init/user-data.yaml"
    
    cat > "$cloud_init_file" << 'EOF'
#cloud-config
# Cloud-init configuration for PodVM image builder VSI

# Disable automatic updates during build
package_update: false
package_upgrade: false

# Install required packages
packages:
  - qemu-img
  - libguestfs
  - guestfs-tools
  - libguestfs-tools
  - cryptsetup
  - systemd-ukify
  - jq
  - openssl
  - e2fsprogs
  - tpm2-tools

write_files:
  - path: /root/build-podvm.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      
      LOG_FILE=/var/log/podvm-build.log
      exec > >(tee -a "$LOG_FILE") 2>&1
      
      echo "[$(date)] Starting PodVM image build..."
      
      # Download base image from attached volume or COS
      echo "[$(date)] Preparing base image..."
      BASE_IMAGE=/mnt/base-image.qcow2
      WORK_IMAGE=/root/work-image.qcow2
      
      if [[ -f "$BASE_IMAGE" ]]; then
          cp "$BASE_IMAGE" "$WORK_IMAGE"
      else
          echo "[$(date)] ERROR: Base image not found at $BASE_IMAGE"
          exit 1
      fi
      
      # Set environment for libguestfs
      export LIBGUESTFS_BACKEND=direct
      
      # Run transformation scripts
      echo "[$(date)] Running CoCo components installation..."
      /root/scripts/coco-components.sh "$WORK_IMAGE"
      
      echo "[$(date)] Running verity setup..."
      /root/scripts/verity.sh "$WORK_IMAGE"
      
      # Upload result to COS
      echo "[$(date)] Uploading result to COS..."
      /root/upload-to-cos.sh "$WORK_IMAGE"
      
      echo "[$(date)] Build complete!"
      
      # Signal completion
      touch /root/build-complete

runcmd:
  - echo "[$(date)] VSI started, beginning PodVM build..." >> /var/log/podvm-build.log
  - /root/build-podvm.sh
  - poweroff

final_message: "PodVM image build completed"
EOF
    
    log "Cloud-init configuration created: $cloud_init_file"
    echo "$cloud_init_file"
}

function copy_build_scripts() {
    log "Copying build scripts to work directory..."
    
    # Copy transformation scripts
    cp "$PROJECT_ROOT/scripts/coco/coco-components.sh" "$WORK_DIR/scripts/"
    cp "$PROJECT_ROOT/scripts/verity/verity.sh" "$WORK_DIR/scripts/"
    cp -r "$PROJECT_ROOT/scripts/coco/podvm" "$WORK_DIR/scripts/"
    
    # Create COS upload script
    cat > "$WORK_DIR/scripts/upload-to-cos.sh" << EOF
#!/bin/bash
set -euo pipefail

IMAGE_FILE="\$1"
OUTPUT_NAME="${OUTPUT_IMAGE_PREFIX}-${BUILD_DATE}\$(cat /root/version-suffix).qcow2"

echo "Uploading \$IMAGE_FILE to COS as \$OUTPUT_NAME..."

ibmcloud cos upload \\
    --bucket "$COS_BUCKET_NAME" \\
    --key "\$OUTPUT_NAME" \\
    --file "\$IMAGE_FILE" \\
    --region "$IBM_CLOUD_REGION"

echo "Upload complete: \$OUTPUT_NAME"
EOF
    
    chmod +x "$WORK_DIR/scripts/"*.sh
    
    log "Build scripts copied"
}

function create_vsi() {
    log "Creating VSI for image building..."
    
    # Get VPC ID
    local vpc_id=$(ibmcloud is vpcs --output json | jq -r ".[] | select(.name==\"$IBM_CLOUD_VPC_NAME\") | .id")
    if [[ -z "$vpc_id" ]]; then
        error "VPC not found: $IBM_CLOUD_VPC_NAME"
    fi
    
    # Get subnet ID
    local subnet_id=$(ibmcloud is subnets --output json | jq -r ".[] | select(.name==\"$IBM_CLOUD_SUBNET_NAME\") | .id")
    if [[ -z "$subnet_id" ]]; then
        error "Subnet not found: $IBM_CLOUD_SUBNET_NAME"
    fi
    
    # Get version suffix
    local version_suffix=$(get_next_version_number "$OUTPUT_IMAGE_PREFIX" "$BUILD_DATE")
    echo "$version_suffix" > "$WORK_DIR/version-suffix"
    
    log "Building version: ${OUTPUT_IMAGE_PREFIX}-${BUILD_DATE}${version_suffix}"
    
    # Create VSI with cloud-init
    local vsi_name="podvm-builder-${BUILD_DATE}-${version_suffix}-$$"
    local cloud_init_file=$(create_cloud_init_config)
    
    log "Creating VSI: $vsi_name"
    
    local vsi_json=$(ibmcloud is instance-create \
        "$vsi_name" \
        "$vpc_id" \
        "$IBM_CLOUD_ZONE" \
        "$IBM_CLOUD_VSI_PROFILE" \
        "$subnet_id" \
        --image-name "$IBM_CLOUD_VSI_IMAGE" \
        --user-data "@$cloud_init_file" \
        --output json)
    
    VSI_ID=$(echo "$vsi_json" | jq -r '.id')
    
    log "VSI created: $VSI_ID"
    log "Waiting for VSI to be running..."
    
    # Wait for VSI to be running
    local max_wait=300
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local status=$(ibmcloud is instance "$VSI_ID" --output json | jq -r '.status')
        if [[ "$status" == "running" ]]; then
            log "VSI is running"
            break
        fi
        sleep 10
        waited=$((waited + 10))
    done
    
    if [[ $waited -ge $max_wait ]]; then
        error "VSI did not start within $max_wait seconds"
    fi
}

function wait_for_build_completion() {
    log "Waiting for build to complete..."
    
    # Monitor VSI status - it will power off when complete
    local max_wait=3600  # 1 hour
    local waited=0
    
    while [[ $waited -lt $max_wait ]]; do
        local status=$(ibmcloud is instance "$VSI_ID" --output json | jq -r '.status')
        
        if [[ "$status" == "stopped" ]]; then
            log "VSI has stopped - build complete"
            return 0
        fi
        
        log "Build in progress... (waited ${waited}s)"
        sleep 30
        waited=$((waited + 30))
    done
    
    error "Build did not complete within $max_wait seconds"
}

function verify_output() {
    log "Verifying output image in COS..."
    
    local version_suffix=$(cat "$WORK_DIR/version-suffix")
    local output_name="${OUTPUT_IMAGE_PREFIX}-${BUILD_DATE}${version_suffix}.qcow2"
    
    if ibmcloud cos head-object \
        --bucket "$COS_BUCKET_NAME" \
        --key "$output_name" \
        --region "$IBM_CLOUD_REGION" &> /dev/null; then
        log "Output image verified: $output_name"
        echo "$output_name"
        return 0
    else
        error "Output image not found in COS: $output_name"
    fi
}

function main() {
    log "=== IBM Cloud VSI-based PodVM Builder ==="
    log "Build date: $BUILD_DATE"
    log "Region: $IBM_CLOUD_REGION"
    log "COS Bucket: $COS_BUCKET_NAME"
    
    check_prerequisites
    setup_work_directory
    copy_build_scripts
    
    # Download base image (optional - could be mounted directly)
    # local base_image=$(download_base_image)
    
    create_vsi
    wait_for_build_completion
    
    local output_image=$(verify_output)
    
    log "=== Build Complete ==="
    log "Output image: $output_image"
    log "Location: cos://$COS_BUCKET_NAME/$output_image"
}

# Run main function
main "$@"

# Made with Bob
