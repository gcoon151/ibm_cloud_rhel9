#!/bin/bash
# Build a RHEL9 qcow2 image from ISO for IBM Cloud VPC import
# This script:
# 1. Downloads the RHEL ISO (if not already present)
# 2. Runs virt-install to create a disk image
# 3. Runs podman to apply CoCo components and dm-verity protection
# 4. Outputs a qcow2 image ready for IBM Cloud VPC import

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env if it exists
if [ -f "$REPO_ROOT/.env" ]; then
    # shellcheck disable=SC1091
    source "$REPO_ROOT/.env"
fi

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_tools=()
    
    for tool in virt-install virsh curl jq podman; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Install them using: sudo dnf install virt-manager podman-docker curl jq"
        exit 1
    fi
    
    # Check if libvirtd is running
    if ! systemctl is-active --quiet libvirtd; then
        log_warn "libvirtd is not running. Starting it..."
        sudo systemctl start libvirtd
    fi
    
    # Check if user is in libvirt group
    if ! id -nG | grep -qw libvirt; then
        log_warn "Current user is not in the libvirt group"
        log_info "Run: sudo usermod -aG libvirt \$USER && newgrp libvirt"
        exit 1
    fi
    
    log_info "All prerequisites met"
}

# Function to download ISO
download_iso() {
    local iso_url="$1"
    local iso_path="$2"
    
    if [ -f "$iso_path" ]; then
        log_info "ISO already exists at $iso_path"
        return 0
    fi
    
    log_info "Downloading ISO from $iso_url"
    log_info "This may take several minutes..."
    
    if ! curl -L -f --progress-bar -o "$iso_path" "$iso_url"; then
        log_error "Failed to download ISO from $iso_url"
        rm -f "$iso_path"
        exit 1
    fi
    
    log_info "ISO downloaded successfully to $iso_path"
}

# Function to create virt-install disk image
create_virt_install_image() {
    local iso_path="$1"
    local qcow2_name="$2"
    local kickstart_location="$3"
    local memory="${4:-8192}"
    local disk_size="${5:-3}"
    
    log_info "Creating VM disk image using virt-install"
    log_info "  ISO: $iso_path"
    log_info "  VM Name: $qcow2_name"
    log_info "  Memory: ${memory}M"
    log_info "  Disk Size: ${disk_size}GB"
    log_info "  Kickstart: $kickstart_location"
    
    # Run virt-install
    if ! sudo virt-install \
        --virt-type kvm \
        --os-variant rhel9.0 \
        --arch x86_64 \
        --boot uefi \
        --name "$qcow2_name" \
        --memory "$memory" \
        --location "$iso_path" \
        --disk bus=scsi,size="$disk_size" \
        --initrd-inject="$kickstart_location" \
        --nographics \
        --extra-args "console=ttyS0 inst.ks=file:/$(basename "$kickstart_location")" \
        --transient; then
        log_error "virt-install failed"
        exit 1
    fi
    
    log_info "VM disk image created successfully"
}

# Function to find the qcow2 image
find_qcow2_image() {
    local qcow2_name="$1"
    local qcow2_path="$HOME/.local/share/libvirt/images/${qcow2_name}.qcow2"
    
    if [ ! -f "$qcow2_path" ]; then
        # Try alternative locations
        local alt_paths=(
            "/var/lib/libvirt/images/${qcow2_name}.qcow2"
            "/tmp/${qcow2_name}.qcow2"
            "$HOME/libvirt/images/${qcow2_name}.qcow2"
        )
        
        for path in "${alt_paths[@]}"; do
            if [ -f "$path" ]; then
                qcow2_path="$path"
                break
            fi
        done
    fi
    
    if [ ! -f "$qcow2_path" ]; then
        log_error "Could not find qcow2 image for VM: $qcow2_name"
        log_info "Searched locations:"
        echo "  $HOME/.local/share/libvirt/images/${qcow2_name}.qcow2"
        for path in "${alt_paths[@]}"; do
            echo "  $path"
        done
        exit 1
    fi
    
    echo "$qcow2_path"
}

# Function to copy qcow2 to working directory
copy_qcow2_to_output() {
    local source_qcow2="$1"
    local output_dir="$2"
    local output_name="$3"
    
    local output_path="${output_dir}/${output_name}.qcow2"
    
    log_info "Copying qcow2 image to output directory"
    log_info "  Source: $source_qcow2"
    log_info "  Destination: $output_path"
    
    mkdir -p "$output_dir"
    cp -v "$source_qcow2" "$output_path"
    
    log_info "qcow2 image copied successfully"
    echo "$output_path"
}

# Function to build podman container
build_podman_container() {
    log_info "Building podman container image"
    
    if ! sudo podman build -t coco-podvm "$REPO_ROOT"; then
        log_error "Failed to build podman container"
        exit 1
    fi
    
    log_info "Podman container built successfully"
}

# Function to run podman to apply CoCo components
run_podman_coco() {
    local qcow2_path="$1"
    local image_type="${2:-}"
    local work_folder="${3:-}"
    local cert_pem="${4:-}"
    local cert_der="${5:-}"
    local private_key="${6:-}"
    
    log_info "Running podman to apply CoCo components and dm-verity protection"
    log_info "  Input Image: $qcow2_path"
    
    # Prepare podman run command
    local podman_cmd=(
        "sudo" "podman" "run" "--rm"
        "--privileged"
        "-v" "$qcow2_path:/disk.qcow2"
        "-v" "/lib/modules:/lib/modules"
        "--user" "0"
        "--security-opt=apparmor=unconfined"
        "--security-opt=seccomp=unconfined"
        "--mount" "type=bind,source=/dev,target=/dev"
        "--mount" "type=bind,source=/run/udev,target=/run/udev"
    )
    
    # Add optional volumes
    if [ -n "$cert_pem" ] && [ -f "$cert_pem" ]; then
        podman_cmd+=("-v" "$cert_pem:/public.pem")
        podman_cmd+=("-e" "IMAGE_CERTIFICATE_PEM=/public.pem")
    fi
    
    if [ -n "$cert_der" ] && [ -f "$cert_der" ]; then
        podman_cmd+=("-v" "$cert_der:/public.der")
        podman_cmd+=("-e" "IMAGE_CERTIFICATE_DER=/public.der")
    fi
    
    if [ -n "$private_key" ] && [ -f "$private_key" ]; then
        podman_cmd+=("-v" "$private_key:/private.key")
        podman_cmd+=("-e" "IMAGE_PRIVATE_KEY=/private.key")
    fi
    
    if [ -n "$work_folder" ]; then
        podman_cmd+=("-e" "WORK_FOLDER=$work_folder")
    fi
    
    if [ -n "$image_type" ]; then
        podman_cmd+=("-e" "IMAGE_TYPE=$image_type")
    fi
    
    # Add container image name
    podman_cmd+=("coco-podvm")
    
    log_debug "Running: ${podman_cmd[*]}"
    
    if ! "${podman_cmd[@]}"; then
        log_error "Podman CoCo processing failed"
        exit 1
    fi
    
    log_info "CoCo components and dm-verity protection applied successfully"
}

# Function to validate qcow2 image
validate_qcow2() {
    local qcow2_path="$1"
    
    log_info "Validating qcow2 image"
    
    if [ ! -f "$qcow2_path" ]; then
        log_error "qcow2 image not found: $qcow2_path"
        exit 1
    fi
    
    local file_type
    file_type=$(file "$qcow2_path" | grep -o "QEMU")
    
    if [ -z "$file_type" ]; then
        log_error "File is not a valid qcow2 image: $qcow2_path"
        exit 1
    fi
    
    local file_size
    file_size=$(du -h "$qcow2_path" | cut -f1)
    
    log_info "qcow2 image validation passed"
    log_info "  File: $qcow2_path"
    log_info "  Size: $file_size"
}

# Function to print usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Build a RHEL9 qcow2 image from ISO for IBM Cloud VPC import.

This script downloads the RHEL ISO, runs virt-install to create a disk image,
and optionally applies CoCo components and dm-verity protection using podman.

OPTIONS:
  -i, --iso-url URL               URL to download RHEL ISO from
                                  Default: \$RHEL_ISO_URL or RedHat CDN
  
  -p, --iso-path PATH             Path where ISO will be stored/found
                                  Default: /tmp/RHEL-9.6.0-x86_64-dvd1.iso
  
  -o, --output-dir DIR            Output directory for final qcow2 image
                                  Default: ./output
  
  -n, --image-name NAME           Name for the qcow2 image
                                  Default: rhel9-podvm-base
  
  -k, --kickstart PATH            Path to kickstart file
                                  Default: ./helpers/rhel9-dm-root.ks
  
  -m, --memory MB                 Memory for VM during installation
                                  Default: 8192
  
  -s, --disk-size GB              Disk size for VM
                                  Default: 3
  
  -c, --skip-coco                 Skip CoCo component application
                                  Default: false (apply CoCo)
  
  -t, --image-type TYPE           CoCo image type (ibm-openshift or blank)
                                  Default: ibm-openshift
  
  --cert-pem PATH                 Path to PEM certificate for secure boot
  
  --cert-der PATH                 Path to DER certificate for secure boot
  
  --private-key PATH              Path to private key for signing
  
  -h, --help                      Show this help message

ENVIRONMENT VARIABLES:
  RHEL_ISO_URL                    URL to download RHEL ISO
  RHEL_ISO_PATH                   Path to store/find RHEL ISO
  OUTPUT_DIR                      Output directory for qcow2
  IMAGE_NAME                      Name for the qcow2 image
  KS_LOCATION                     Path to kickstart file
  IMAGE_TYPE                      CoCo image type
  IMAGE_CERTIFICATE_PEM           Path to PEM certificate
  IMAGE_CERTIFICATE_DER           Path to DER certificate
  IMAGE_PRIVATE_KEY               Path to private key

EXAMPLES:
  # Basic usage with default settings
  $0
  
  # Specify custom ISO URL and output directory
  $0 --iso-url "https://mirrors.example.com/rhel9.iso" --output-dir ./images
  
  # Build with CoCo components and certificates
  $0 --cert-pem ./certs/public.pem --cert-der ./certs/public.der --private-key ./certs/private.key
  
  # Skip CoCo components, just build base image
  $0 --skip-coco

EOF
}

# Default values
RHEL_ISO_URL="${RHEL_ISO_URL:-https://access.redhat.com/downloads/content/rhel/rhel-9/9.6/x86_64/product-dvd/files/RHEL-9.6.0-x86_64-dvd1.iso}"
RHEL_ISO_PATH="${RHEL_ISO_PATH:-/tmp/RHEL-9.6.0-x86_64-dvd1.iso}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
IMAGE_NAME="${IMAGE_NAME:-rhel9-podvm-base}"
KS_LOCATION="${KS_LOCATION:-$REPO_ROOT/helpers/rhel9-dm-root.ks}"
MEMORY="${MEMORY:-8192}"
DISK_SIZE="${DISK_SIZE:-3}"
SKIP_COCO="false"
IMAGE_TYPE="${IMAGE_TYPE:-ibm-openshift}"
CERT_PEM="${IMAGE_CERTIFICATE_PEM:-}"
CERT_DER="${IMAGE_CERTIFICATE_DER:-}"
PRIVATE_KEY="${IMAGE_PRIVATE_KEY:-}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--iso-url)
            RHEL_ISO_URL="$2"
            shift 2
            ;;
        -p|--iso-path)
            RHEL_ISO_PATH="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -n|--image-name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -k|--kickstart)
            KS_LOCATION="$2"
            shift 2
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        -s|--disk-size)
            DISK_SIZE="$2"
            shift 2
            ;;
        -c|--skip-coco)
            SKIP_COCO="true"
            shift
            ;;
        -t|--image-type)
            IMAGE_TYPE="$2"
            shift 2
            ;;
        --cert-pem)
            CERT_PEM="$2"
            shift 2
            ;;
        --cert-der)
            CERT_DER="$2"
            shift 2
            ;;
        --private-key)
            PRIVATE_KEY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate paths
if [ ! -f "$KS_LOCATION" ]; then
    log_error "Kickstart file not found: $KS_LOCATION"
    exit 1
fi

# Make paths absolute
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_DIR")" && pwd)/$(basename "$OUTPUT_DIR")"
KS_LOCATION="$(cd "$(dirname "$KS_LOCATION")" && pwd)/$(basename "$KS_LOCATION")"

log_info "=========================================="
log_info "RHEL9 qcow2 Image Build for IBM Cloud VPC"
log_info "=========================================="
log_info "ISO URL: $RHEL_ISO_URL"
log_info "ISO Path: $RHEL_ISO_PATH"
log_info "Output Directory: $OUTPUT_DIR"
log_info "Image Name: $IMAGE_NAME"
log_info "Kickstart: $KS_LOCATION"
log_info "Memory: ${MEMORY}M, Disk: ${DISK_SIZE}GB"
log_info "Skip CoCo: $SKIP_COCO"
log_info "=========================================="

# Execute steps
check_prerequisites
download_iso "$RHEL_ISO_URL" "$RHEL_ISO_PATH"
create_virt_install_image "$RHEL_ISO_PATH" "$IMAGE_NAME" "$KS_LOCATION" "$MEMORY" "$DISK_SIZE"

# Find and copy the qcow2 image
QCOW2_SOURCE=$(find_qcow2_image "$IMAGE_NAME")
QCOW2_OUTPUT=$(copy_qcow2_to_output "$QCOW2_SOURCE" "$OUTPUT_DIR" "$IMAGE_NAME")

# Apply CoCo components if requested
if [ "$SKIP_COCO" = "false" ]; then
    log_info "Preparing to apply CoCo components..."
    build_podman_container
    run_podman_coco "$QCOW2_OUTPUT" "$IMAGE_TYPE" "" "$CERT_PEM" "$CERT_DER" "$PRIVATE_KEY"
fi

# Validate final image
validate_qcow2 "$QCOW2_OUTPUT"

log_info "=========================================="
log_info "qcow2 image build completed successfully!"
log_info "=========================================="
log_info "Output image: $QCOW2_OUTPUT"
log_info ""
log_info "Next steps:"
log_info "1. You can now import this image to IBM Cloud VPC using:"
log_info "   ./ibmcloud/import-vpc-custom-image.sh $QCOW2_OUTPUT"
log_info ""
log_info "2. Make sure to set the following environment variables:"
log_info "   - IBM_CLOUD_API_KEY"
log_info "   - IBM_CLOUD_REGION (default: us-east)"
log_info "   - COS_BUCKET_NAME"
log_info "   - COS_BUCKET_CRN"
log_info "=========================================="
