#!/bin/bash
# Rebuild base QCOW2 image with latest packages (including CVE fixes)
# This script is SAFE - it creates a NEW image and backs up the old one

set -e

# Load Red Hat subscription credentials from .env file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
    echo "Loaded credentials from $ENV_FILE"
else
    echo "ERROR: .env file not found at $ENV_FILE"
    echo "Please create .env with ORG_ID and ACTIVATION_KEY"
    exit 1
fi

if [ -z "$ORG_ID" ] || [ -z "$ACTIVATION_KEY" ]; then
    echo "ERROR: ORG_ID and ACTIVATION_KEY must be set in .env"
    exit 1
fi

ISO_PATH="/home/gcoon/Downloads/rhel-9.7-x86_64-dvd.iso"
KS_FILE="$(dirname $0)/rhel9-dm-root.ks"
OLD_IMAGE="/home/gcoon/.local/share/libvirt/images/rhel97-ks-READONLY.qcow2"
BACKUP_IMAGE="/home/gcoon/.local/share/libvirt/images/rhel97-ks-READONLY-BACKUP-$(date +%Y%m%d).qcow2"
VM_NAME="rhel97-ks-READONLY"
IMAGE_DIR="/home/gcoon/.local/share/libvirt/images"

echo "=========================================="
echo "Base Image Rebuild Script"
echo "=========================================="
echo ""
echo "This script will:"
echo "  1. Backup existing image to: $(basename $BACKUP_IMAGE)"
echo "  2. Rebuild image at: $(basename $OLD_IMAGE)"
echo "  3. Use --transient so VM is destroyed after install"
echo ""
echo "ISO: $ISO_PATH"
echo "Kickstart: $KS_FILE"
echo ""

# Verify files exist
if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: ISO not found at $ISO_PATH"
    exit 1
fi

if [ ! -f "$KS_FILE" ]; then
    echo "ERROR: Kickstart file not found at $KS_FILE"
    exit 1
fi

if [ ! -f "$OLD_IMAGE" ]; then
    echo "WARNING: Old image not found at $OLD_IMAGE"
    echo "This appears to be a fresh install"
else
    echo "Found existing image: $OLD_IMAGE"
fi

echo ""
read -p "Continue with base image rebuild? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted by user"
    exit 0
fi

echo ""
echo "=========================================="
echo "Step 1: Backup existing image"
echo "=========================================="

if [ -f "$OLD_IMAGE" ]; then
    if [ -f "$BACKUP_IMAGE" ]; then
        echo "Backup already exists: $BACKUP_IMAGE"
    else
        echo "Creating backup..."
        cp "$OLD_IMAGE" "$BACKUP_IMAGE"
        echo "✓ Backup created: $BACKUP_IMAGE"
    fi
else
    echo "No existing image to backup"
fi

echo ""
echo "=========================================="
echo "Step 2: Create new base image"
echo "=========================================="
echo ""
echo "This will take 10-15 minutes..."
echo "The VM will install RHEL 9.7 with latest packages"
echo ""

# virt-install will create the image automatically
# Using --transient means VM is destroyed after install completes

# Create new base image
# Using exact command from README.md - virt-install will create disk automatically
# Pass subscription credentials as kernel parameters for kickstart to use
virt-install \
    --virt-type kvm \
    --os-variant rhel9.0 \
    --arch x86_64 \
    --boot uefi \
    --name "$VM_NAME" \
    --memory 8192 \
    --location "$ISO_PATH" \
    --disk bus=scsi,size=3 \
    --initrd-inject="$KS_FILE" \
    --nographics \
    --extra-args "console=ttyS0 inst.ks=file:/rhel9-dm-root.ks ORG_ID=$ORG_ID ACTIVATION_KEY=$ACTIVATION_KEY" \
    --transient

echo ""
echo "=========================================="
echo "Step 3: Find and verify created image"
echo "=========================================="
echo ""

# Find the newest image matching our VM name (virt-install may add -1, -2, etc suffix)
CREATED_IMAGE=$(ls -t ${IMAGE_DIR}/${VM_NAME}*.qcow2 2>/dev/null | head -1)

if [ -z "$CREATED_IMAGE" ] || [ ! -f "$CREATED_IMAGE" ]; then
    echo "ERROR: No image found matching ${VM_NAME}*.qcow2"
    echo "Looking for images..."
    ls -lh ${IMAGE_DIR}/${VM_NAME}*.qcow2 2>/dev/null || echo "No images found"
    exit 1
fi

echo "Found created image: $CREATED_IMAGE"
echo "Size: $(du -h $CREATED_IMAGE | cut -f1)"
echo "Created: $(stat -c %y $CREATED_IMAGE | cut -d. -f1)"

echo ""
echo "=========================================="
echo "SUCCESS: Base image rebuilt"
echo "=========================================="
echo ""
echo "Image: $CREATED_IMAGE"
echo "Backup: $BACKUP_IMAGE"
echo ""
echo "The image is ready to use for PodVM builds."
echo ""

# Made with Bob
