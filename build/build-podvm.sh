#!/bin/bash
# Complete PodVM Build Script
# Run this on gcoon@192.168.1.196
#
# Usage:
#   ./build-podvm.sh                    # Build both payload binaries and QCOW2 image
#   ./build-podvm.sh binaries           # Build only payload binaries container
#   ./build-podvm.sh qcow2              # Build only QCOW2 image (requires existing binaries)
#   ./build-podvm.sh qcow2 --skip-upload # Build QCOW2 but skip COS upload

set -e

MODE="${1:-all}"
SKIP_UPLOAD="${2:-}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Capture environment variables passed from remote-build.sh before loading .env
CMD_SSHD_SERVICE="${SSHD_SERVICE:-}"
CMD_APPLY_VERITY="${APPLY_VERITY:-}"
CMD_PODVM_TAG="${PODVM_TAG:-}"
CMD_UPDATE_KERNEL="${UPDATE_KERNEL:-}"

# Load credentials from .env file if it exists
if [ -f ~/.env ]; then
    source ~/.env
elif [ -f "$(dirname "$0")/../.env" ]; then
    source "$(dirname "$0")/../.env"
else
    log_warn "No .env file found. Using environment variables or defaults."
fi

# Configuration - environment variables passed from remote-build.sh take precedence over .env
ORG_ID="${ORG_ID:-}"
ACTIVATION_KEY="${ACTIVATION_KEY:-}"
PAYLOAD_TAG="${CMD_PODVM_TAG:-${PODVM_TAG:-ffb785e}}"  # Command-line > .env > default
PAYLOAD_IMAGE="registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9:${PAYLOAD_TAG}"
SSHD_SERVICE="${CMD_SSHD_SERVICE:-${SSHD_SERVICE:-true}}"  # Command-line > .env > default
APPLY_VERITY="${CMD_APPLY_VERITY:-${APPLY_VERITY:-false}}"  # Command-line > .env > default
UPDATE_KERNEL="${CMD_UPDATE_KERNEL:-${UPDATE_KERNEL:-false}}"  # Command-line > .env > default

# Validate required credentials
if [ -z "$ORG_ID" ] || [ -z "$ACTIVATION_KEY" ]; then
    log_error "Missing required credentials: ORG_ID and ACTIVATION_KEY"
    log_error "Please create a .env file from .env.example and fill in your credentials"
    exit 1
fi

echo "=========================================="
echo "  PodVM Build Script"
echo "=========================================="
echo "Mode: $MODE"
echo "Timestamp: $(date)"
echo ""

###########################################
# FUNCTION: Build Payload Binaries
###########################################
build_binaries() {
    log_info "=== Building Payload Binaries ==="
    
    # Navigate to build directory
    cd ~/gits/ibm_cloud_rhel9/cloud-api-adaptor || {
        log_error "Build directory not found: ~/gits/ibm_cloud_rhel9/cloud-api-adaptor"
        exit 1
    }
    
    log_info "Working directory: $(pwd)"
    
    # Create secret files
    echo "$ORG_ID" > org_secret.txt
    echo "$ACTIVATION_KEY" > key_secret.txt
    log_info "Secret files created"
    
    # Show Dockerfile info
    log_info "Dockerfile: src/cloud-api-adaptor/podvm/Dockerfile.podvm_binaries.rhel (first 20 lines)"
    head -20 src/cloud-api-adaptor/podvm/Dockerfile.podvm_binaries.rhel | sed 's/^/  /'
    echo "  ..."
    echo ""
    
    # Check registry login
    if podman login --get-login quay.io &>/dev/null; then
        log_info "Logged into quay.io ✓"
    else
        log_warn "Not logged into quay.io - you may need to run: podman login quay.io"
    fi
    
    # Build command
    log_info "Building payload image: $PAYLOAD_IMAGE"
    echo ""
    
    time podman build \
        -t "$PAYLOAD_IMAGE" \
        -f src/cloud-api-adaptor/podvm/Dockerfile.podvm_binaries.rhel \
        --secret id=org,src=org_secret.txt \
        --secret id=key,src=key_secret.txt \
        --build-arg ARCH=x86_64 \
        .
    
    if [ $? -eq 0 ]; then
        log_info "Payload build SUCCESSFUL ✓"
        log_info "Image: $PAYLOAD_IMAGE"
        
        # Auto-push to registry (skip prompt for 'latest' tag)
        echo ""
        if [ "$PAYLOAD_TAG" = "latest" ]; then
            read -p "Push 'latest' tag to registry? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_info "Pushing to registry..."
                podman push "$PAYLOAD_IMAGE"
                log_info "Image pushed to registry ✓"
            fi
        else
            # Auto-push candidate and other tags
            log_info "Pushing to registry..."
            podman push "$PAYLOAD_IMAGE"
            log_info "Image pushed to registry ✓"
        fi
    else
        log_error "Payload build FAILED"
        exit 1
    fi
    
    echo ""
}

###########################################
# FUNCTION: Build QCOW2 Image
###########################################
build_qcow2() {
    log_info "=== Building QCOW2 Image ==="
    
    # Copy Uptycs tarball from edr/ to scripts/coco/podvm/ BEFORE checking payload
    # This is required because the Dockerfile copies scripts/ into the container at BUILD time
    cd ~/gits/ibm_cloud_rhel9 || exit 1
    UPTYCS_TARBALL=$(ls -t edr/uptycs-complete*.tar.gz 2>/dev/null | head -1)
    if [ -n "$UPTYCS_TARBALL" ]; then
        log_info "Found Uptycs package: $UPTYCS_TARBALL"
        cp "$UPTYCS_TARBALL" scripts/coco/podvm/uptycs-complete.tar.gz
        log_info "✓ Copied to scripts/coco/podvm/ for container build"
    else
        log_warn "No Uptycs package found in edr/ - build will proceed without Uptycs"
    fi
    
    # For qcow2-only mode, check if Red Hat upstream image exists locally
    if [ "$MODE" = "qcow2" ]; then
        # Check if Red Hat image is already pulled (use podman image exists for reliable check)
        if ! podman image exists "$PAYLOAD_IMAGE"; then
            log_info "Pulling Red Hat upstream payload image..."
            podman pull "$PAYLOAD_IMAGE" || {
                log_error "Failed to pull Red Hat payload image: $PAYLOAD_IMAGE"
                log_error "Image may need to be pulled manually with Red Hat credentials"
                exit 1
            }
        else
            log_info "Using locally cached Red Hat payload image"
        fi
        log_info "Payload: $PAYLOAD_IMAGE"
    fi
    
    # Navigate to ibm_cloud_rhel9 (consolidated build directory)
    cd ~/gits/ibm_cloud_rhel9 || {
        log_error "Directory not found: ~/gits/ibm_cloud_rhel9"
        exit 1
    }
    
    log_info "Working directory: $(pwd)"
    
    # Set environment variables
    export ORG_ID
    export ACTIVATION_KEY
    export PODVM_BINARY="$PAYLOAD_IMAGE"
    export SSHD_SERVICE
    export APPLY_VERITY
    export UPDATE_KERNEL
    
    # NOTE: Custom Secure Boot signing is DISABLED for IBM Cloud TDX
    # Reasons:
    # 1. Signing with custom keys triggers MOK enrollment at boot (doesn't work for automated deployments)
    # 2. dm-verity roothash is now passed via initdata at runtime (not baked into UKI)
    # 3. The UKI boots with Secure Boot enabled using Red Hat's default keys
    # 4. No need to rebuild/sign UKI since we don't modify kernel cmdline in the image
    # If custom signing is needed in the future, uncomment these lines:
    # export IMAGE_CERTIFICATE=/home/gcoon/gits/ibm_cloud_rhel9/certs/public_key.pem
    # export IMAGE_PRIVATE_KEY=/home/gcoon/gits/ibm_cloud_rhel9/certs/private.key
    
    log_info "Environment configured:"
    echo "  ORG_ID: $ORG_ID"
    echo "  ACTIVATION_KEY: ${ACTIVATION_KEY:0:8}..."
    echo "  PODVM_BINARY: $PODVM_BINARY"
    echo "  SSHD_SERVICE: $SSHD_SERVICE"
    echo "  APPLY_VERITY: $APPLY_VERITY"
    echo "  UPDATE_KERNEL: $UPDATE_KERNEL"
    echo "  Secure Boot: Using Red Hat default keys (no custom signing)"
    if [ "$APPLY_VERITY" = "true" ]; then
        echo "  dm-verity: Enabled (partition created at build time)"
    else
        echo "  dm-verity: Disabled (roothash passed via initdata at runtime)"
    fi
    echo ""
    
    # Clone base QCOW2 image
    dir="/home/gcoon/.local/share/libvirt/images"
    src="${dir}/rhel97-ks-READONLY.qcow2"
    
    if [ ! -f "$src" ]; then
        log_error "Base QCOW2 not found: $src"
        exit 1
    fi
    
    log_info "Base image: $src"
    
    # Generate unique filename
    date=$(date +%Y%m%d)
    n=1
    while :; do
        nn=$(printf "%02d" "$n")
        dst="${dir}/rhel97-${date}${nn}.qcow2"
        [[ -e "$dst" ]] || break
        ((n++))
    done
    
    log_info "Creating: $dst"
    rm -f "$dst"  # Remove if exists (may have mode 600 from previous run)
    cp "$src" "$dst"
    chmod 600 "$dst"
    
    export QCOW2="$dst"
    export QCOW2_DIR="$(dirname "$dst")"
    
    # Run the build
    log_info "Running example_run.sh..."
    echo ""
    
    time ./example_run.sh
    
    if [ $? -eq 0 ]; then
        # Repair QCOW2 metadata corruption caused by dm-verity/systemd-repart
        # This must happen AFTER the container exits (image no longer locked)
        if [ "$APPLY_VERITY" = "true" ]; then
            log_info "Repairing QCOW2 metadata after dm-verity creation..."
            if qemu-img check -r all "$QCOW2" 2>&1 | tee /tmp/qemu-img-repair.log | grep -q "Repairing"; then
                log_info "✓ QCOW2 metadata repaired"
            else
                log_info "✓ No repairs needed"
            fi
        fi
        
        log_info "QCOW2 build SUCCESSFUL ✓"
        log_info "Image: $QCOW2"
        echo ""
        log_info "Image details:"
        qemu-img info "$QCOW2" | sed 's/^/  /'
        echo ""
        
        # Check for Uptycs installation log (run in container where libguestfs is configured)
        log_info "Checking Uptycs installation log..."
        if podman run --rm --privileged \
            -v "$QCOW2_DIR:/images:ro" \
            localhost/coco-podvm:latest \
            virt-cat -a "/images/$(basename $QCOW2)" /var/log/uptycs-install.log 2>/dev/null; then
            echo ""
            log_info "✓ Uptycs installation log found and displayed above"
        else
            log_warn "Uptycs installation log not found in image"
        fi
        
        # Check Uptycs installation status using marker files (run in container)
        log_info "Checking Uptycs installation status..."
        if podman run --rm --privileged \
            -v "$QCOW2_DIR:/images:ro" \
            localhost/coco-podvm:latest \
            virt-ls -a "/images/$(basename $QCOW2)" / 2>/dev/null | grep -q "UPTYCS_INSTALL_SUCCESS"; then
            log_info "✓ Uptycs installation completed successfully"
            # Verify binary exists
            if podman run --rm --privileged \
                -v "$QCOW2_DIR:/images:ro" \
                localhost/coco-podvm:latest \
                virt-ls -a "/images/$(basename $QCOW2)" /usr/bin/ 2>/dev/null | grep -q osqueryd; then
                log_info "✓ Uptycs binary confirmed at /usr/bin/osqueryd"
            else
                log_warn "WARNING: Install script succeeded but binary not found!"
            fi
        elif podman run --rm --privileged \
            -v "$QCOW2_DIR:/images:ro" \
            localhost/coco-podvm:latest \
            virt-ls -a "/images/$(basename $QCOW2)" / 2>/dev/null | grep -q "UPTYCS_INSTALL_STARTED"; then
            log_error "Uptycs installation STARTED but did NOT complete"
            log_error "The install script failed partway through"
        else
            log_warn "Uptycs installation script may not have run"
        fi
        echo ""
        
        # Verify QCOW2 integrity before proceeding
        log_info "Verifying QCOW2 image integrity..."
        if ! qemu-img check "$QCOW2" 2>&1 | tee /tmp/qemu-img-check.log; then
            log_error "QCOW2 image has corruption errors!"
            log_error "This usually indicates a problem during dm-verity partition creation"
            cat /tmp/qemu-img-check.log
            log_error "Build failed - image is corrupted and cannot be used"
            rm -f "$QCOW2"
            exit 1
        fi
        log_info "✓ QCOW2 image integrity verified"
        echo ""
        
        # Auto-upload to IBM Cloud if upload script exists (unless --skip-upload)
        if [ "$SKIP_UPLOAD" = "--skip-upload" ]; then
            log_warn "Skipping COS upload (--skip-upload flag set)"
            log_info "To upload manually:"
            echo "  cd $dir"
            echo "  ./upload_hl_dev_cos_bucket.sh $QCOW2"
        elif [ -f "$dir/upload_hl_dev_cos_bucket.sh" ]; then
            log_info "Uploading to IBM Cloud Object Storage..."
            cd "$dir"
            # Add timeout to prevent hanging (5 minutes max)
            if timeout 300 ./upload_hl_dev_cos_bucket.sh "$QCOW2"; then
                log_info "Upload to IBM Cloud SUCCESSFUL ✓"
            else
                EXIT_CODE=$?
                if [ $EXIT_CODE -eq 124 ]; then
                    log_error "Upload TIMED OUT after 5 minutes"
                else
                    log_error "Upload to IBM Cloud FAILED (exit code: $EXIT_CODE)"
                fi
                log_warn "Continuing anyway - image is built successfully"
            fi
        else
            log_warn "Upload script not found: $dir/upload_hl_dev_cos_bucket.sh"
            log_info "To upload manually:"
            echo "  cd $dir"
            echo "  ./upload_hl_dev_cos_bucket.sh $QCOW2"
        fi
    else
        log_error "QCOW2 build FAILED"
        log_warn "Cleaning up failed image: $dst"
        rm -f "$dst"
        exit 1
    fi
    
    echo ""
}

###########################################
# MAIN
###########################################

case "$MODE" in
    binaries)
        build_binaries
        ;;
    qcow2)
        build_qcow2
        ;;
    all)
        build_binaries
        echo ""
        echo "=========================================="
        echo ""
        build_qcow2
        ;;
    *)
        log_error "Invalid mode: $MODE"
        echo "Usage: $0 [all|binaries|qcow2]"
        exit 1
        ;;
esac

echo "=========================================="
log_info "Build complete!"
echo "=========================================="

# Made with Bob
