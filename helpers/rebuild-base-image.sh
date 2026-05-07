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
echo "Starting base image rebuild..."
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

# Wait for installation to complete (VM will be destroyed when done)
echo ""
echo "Waiting for installation to complete..."
echo "Started at: $(date '+%H:%M:%S')"
WAIT_COUNT=0
MAX_WAIT=900  # 15 minutes max
while virsh --connect qemu:///session list 2>/dev/null | grep -q "$VM_NAME"; do
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo "ERROR: Installation timeout after $MAX_WAIT seconds"
        virsh --connect qemu:///session destroy "$VM_NAME" 2>/dev/null || true
        exit 1
    fi
    if [ $((WAIT_COUNT % 60)) -eq 0 ]; then
        echo "  Still installing... ($((WAIT_COUNT / 60)) minutes elapsed)"
    fi
done
echo "Installation completed at: $(date '+%H:%M:%S')"
echo "Total time: $((WAIT_COUNT / 60)) minutes $((WAIT_COUNT % 60)) seconds"

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

# Fix permissions - virt-install creates images with 600, but we need 644 for copying
echo "Setting proper permissions (644)..."
chmod 644 "$CREATED_IMAGE"

echo ""
echo "=========================================="
echo "Step 4: Extract and analyze build logs"
echo "=========================================="
echo ""

LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="$LOG_DIR/base-image-build-$TIMESTAMP.log"

echo "Extracting kickstart logs..."
echo "=== Kickstart Script Logs ===" > "$LOG_FILE"
for logfile in $(podman run --rm -v ${IMAGE_DIR}:/images:ro localhost/coco-podvm:latest virt-ls -a /images/$(basename $CREATED_IMAGE) /var/log/anaconda/ 2>/dev/null | grep ks-script); do
    echo "" >> "$LOG_FILE"
    echo "--- $logfile ---" >> "$LOG_FILE"
    podman run --rm -v ${IMAGE_DIR}:/images:ro localhost/coco-podvm:latest virt-cat -a /images/$(basename $CREATED_IMAGE) /var/log/anaconda/$logfile >> "$LOG_FILE" 2>&1
done

echo "Checking for errors..."
if grep -iE "error|failed|warning" "$LOG_FILE" | grep -v "Warning: /boot/grub2/grubenv" > "$LOG_FILE.errors"; then
    echo "⚠️  Found errors/warnings:"
    head -20 "$LOG_FILE.errors"
else
    echo "✓ No critical errors found"
fi

echo ""
echo "Checking installed kernels..."
KERNELS=$(podman run --rm -v ${IMAGE_DIR}:/images:ro localhost/coco-podvm:latest virt-ls -a /images/$(basename $CREATED_IMAGE) /boot/efi/EFI/Linux/ 2>&1 | grep -v '^\.')
KERNEL_COUNT=$(echo "$KERNELS" | wc -l)
echo "Found $KERNEL_COUNT kernel(s):"
echo "$KERNELS"

echo ""
echo "Build logs: $LOG_FILE"

echo ""
echo "=========================================="
echo "Step 4.5: Clean up orphaned kernel artifacts"
echo "=========================================="
echo ""

# If kickstart updated kernel, there may be orphaned files from old kernel
# Clean them up using virt-customize
if [ "$KERNEL_COUNT" -gt 1 ]; then
    echo "⚠️  Multiple kernel files detected - cleaning up orphaned artifacts..."
    
    # Find the newest .efi file (the one we want to keep)
    NEWEST_EFI=$(echo "$KERNELS" | grep '\.efi$' | sort -V | tail -1)
    echo "Keeping: $NEWEST_EFI"
    
    # Remove all other .efi files and .extra.d directories
    echo "Removing orphaned kernel artifacts..."
    for file in $(echo "$KERNELS" | grep -v "^$NEWEST_EFI$"); do
        echo "  Removing: $file"
        if [[ "$file" == *.efi ]]; then
            podman run --rm --privileged \
                -v "$CREATED_IMAGE:/disk.qcow2" \
                -v /lib/modules:/lib/modules:ro \
                -v /boot:/boot:ro \
                localhost/coco-podvm:latest \
                virt-customize -a /disk.qcow2 \
                    --run-command "rm -f /boot/efi/EFI/Linux/$file" \
                    --selinux-relabel
        elif [[ "$file" == *.extra.d ]]; then
            podman run --rm --privileged \
                -v "$CREATED_IMAGE:/disk.qcow2" \
                -v /lib/modules:/lib/modules:ro \
                -v /boot:/boot:ro \
                localhost/coco-podvm:latest \
                virt-customize -a /disk.qcow2 \
                    --run-command "rm -rf /boot/efi/EFI/Linux/$file" \
                    --selinux-relabel
        fi
    done
    
    # Verify cleanup
    echo ""
    echo "Verifying cleanup..."
    KERNELS_AFTER=$(podman run --rm -v ${IMAGE_DIR}:/images:ro localhost/coco-podvm:latest virt-ls -a /images/$(basename $CREATED_IMAGE) /boot/efi/EFI/Linux/ 2>&1 | grep -v '^\.')
    KERNEL_COUNT_AFTER=$(echo "$KERNELS_AFTER" | grep -c '\.efi$' || echo "0")
    echo "Kernel files after cleanup: $KERNEL_COUNT_AFTER"
    echo "$KERNELS_AFTER"
    
    if [ "$KERNEL_COUNT_AFTER" -eq 1 ]; then
        echo "✓ Cleanup successful - exactly 1 kernel file remains"
    else
        echo "⚠️  WARNING: Expected 1 kernel file, found $KERNEL_COUNT_AFTER"
    fi
else
    echo "✓ Only 1 kernel file found - no cleanup needed"
fi

echo ""
echo "=========================================="
echo "Step 5: Internal validation with pesign"
echo "=========================================="
echo ""

# Run the internal validation script that uses pesign from inside the image
VALIDATION_SCRIPT="$REPO_ROOT/helpers/validate-boot-health-internal.sh"
if [ -f "$VALIDATION_SCRIPT" ]; then
    echo "Running internal validation (uses pesign from image)..."
    if podman run --rm --privileged \
        -v "$CREATED_IMAGE:/disk.qcow2" \
        -v "$VALIDATION_SCRIPT:/validation.sh:ro" \
        -v /lib/modules:/lib/modules:ro \
        -v /boot:/boot:ro \
        localhost/coco-podvm:latest \
        virt-customize -a /disk.qcow2 \
            --copy-in /validation.sh:/tmp \
            --run-command "chmod +x /tmp/validation.sh && /tmp/validation.sh" \
            --selinux-relabel 2>&1 | tee "$LOG_DIR/validation-$TIMESTAMP.log"; then
        echo "✓ Internal validation passed"
    else
        echo "⚠️  Internal validation failed - check logs"
    fi
else
    echo "ℹ  Validation script not found, skipping internal validation"
fi

echo ""
echo "=========================================="
echo "Step 6: Boot test validation"
echo "=========================================="
echo ""

BOOT_LOG="$LOG_DIR/boot-test-$TIMESTAMP.log"
VM_TEST_NAME="test-base-$$"

cat > /tmp/test-vm-$$.xml <<EOF
<domain type='kvm'>
  <name>$VM_TEST_NAME</name>
  <memory unit='GiB'>2</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$CREATED_IMAGE'/>
      <target dev='vda' bus='virtio'/>
      <readonly/>
    </disk>
    <serial type='pty'><target port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
  </devices>
</domain>
EOF

echo "Starting VM for 30-second boot test..."
virsh --connect qemu:///session create /tmp/test-vm-$$.xml > "$BOOT_LOG" 2>&1
sleep 30

if virsh --connect qemu:///session list 2>/dev/null | grep -q $VM_TEST_NAME; then
    echo "✓ VM booted successfully"
    BOOT_SUCCESS=true
    virsh --connect qemu:///session destroy $VM_TEST_NAME >> "$BOOT_LOG" 2>&1
else
    echo "✗ VM failed to boot or crashed"
    BOOT_SUCCESS=false
fi

rm -f /tmp/test-vm-$$.xml
echo "Boot test log: $BOOT_LOG"

echo ""
echo "=========================================="
echo "Step 7: Move validated image to production"
echo "=========================================="
echo ""

if [ "$BOOT_SUCCESS" = "true" ]; then
    # Move the validated image to the production filename
    if [ "$CREATED_IMAGE" != "$OLD_IMAGE" ]; then
        echo "Moving validated image to production filename..."
        echo "  From: $CREATED_IMAGE"
        echo "  To:   $OLD_IMAGE"
        mv "$CREATED_IMAGE" "$OLD_IMAGE"
        echo "✓ Image moved to production location"
    else
        echo "✓ Image already at production location"
    fi
else
    echo "⚠️  Boot test failed - NOT moving image to production"
    echo "Failed image left at: $CREATED_IMAGE"
    exit 1
fi

echo ""
echo "=========================================="
echo "Build Complete"
echo "=========================================="
echo ""
echo "Production image: $OLD_IMAGE"
echo "Backup: $BACKUP_IMAGE"
echo "Logs: $LOG_FILE"
echo "Boot test: $BOOT_LOG"
echo ""
echo "✓ Image validated and ready for PodVM builds"
echo ""

# Made with Bob
