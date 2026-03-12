#!/bin/bash
# Install dracut dm-verity module into the image
# This script is run during image build via virt-customize

set -euo pipefail

LOG_FILE="/var/log/dracut-dmverity-install.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "==========================================
  Installing Dracut dm-verity Module
=========================================="

# Check if dracut is installed
if ! command -v dracut &> /dev/null; then
    log "ERROR: dracut not found"
    exit 1
fi

# Create dracut module directory
DRACUT_MODULE_DIR="/usr/lib/dracut/modules.d/90dmverity"
log "Creating dracut module directory: $DRACUT_MODULE_DIR"
mkdir -p "$DRACUT_MODULE_DIR"

# Copy module files (should be in /tmp during virt-customize)
if [ -f "/tmp/90dmverity/module-setup.sh" ]; then
    cp /tmp/90dmverity/module-setup.sh "$DRACUT_MODULE_DIR/"
    chmod +x "$DRACUT_MODULE_DIR/module-setup.sh"
    log "✓ Installed module-setup.sh"
else
    log "ERROR: /tmp/90dmverity/module-setup.sh not found"
    exit 1
fi

if [ -f "/tmp/90dmverity/dmverity-setup.sh" ]; then
    cp /tmp/90dmverity/dmverity-setup.sh "$DRACUT_MODULE_DIR/"
    chmod +x "$DRACUT_MODULE_DIR/dmverity-setup.sh"
    log "✓ Installed dmverity-setup.sh"
else
    log "ERROR: /tmp/90dmverity/dmverity-setup.sh not found"
    exit 1
fi

# Install required packages for dm-verity
log "Installing dm-verity tools..."
dnf install -y device-mapper cryptsetup || {
    log "ERROR: Failed to install dm-verity tools"
    exit 1
}

# Regenerate initramfs with new module
log "Regenerating initramfs..."
KERNEL_VERSION=$(ls /lib/modules/ | head -1)
log "Kernel version: $KERNEL_VERSION"

# Add dm-verity module to dracut configuration
cat > /etc/dracut.conf.d/90-dmverity.conf <<EOF
# Enable dm-verity dracut module
add_dracutmodules+=" dmverity "
# Include dm-verity kernel modules
add_drivers+=" dm-verity dm-mod "
# Include required tools
install_items+=" /usr/sbin/dmsetup /usr/sbin/veritysetup /usr/bin/blockdev "
EOF

log "✓ Created dracut configuration"

# Regenerate initramfs
if dracut -f --kver "$KERNEL_VERSION"; then
    log "✓ Initramfs regenerated successfully"
else
    log "ERROR: Failed to regenerate initramfs"
    exit 1
fi

# Verify module is included
log "Verifying dracut module installation..."
if lsinitrd "/boot/initramfs-${KERNEL_VERSION}.img" | grep -q "90dmverity"; then
    log "✓ dm-verity module found in initramfs"
else
    log "WARN: dm-verity module not found in initramfs (may be normal)"
fi

log "==========================================
  Dracut dm-verity Module Installation Complete
=========================================="

log "The module will:"
log "  1. Run in initramfs BEFORE root mount"
log "  2. Read roothash from kernel cmdline (rd.verity.roothash=...)"
log "  3. Create /dev/mapper/root-verity device"
log "  4. Mount it as root with read-only + overlay"
log ""
log "To enable at boot, pass kernel parameters:"
log "  rd.verity.enable=1"
log "  rd.verity.roothash=<64-char-hex-hash>"
log "  rd.verity.data=/dev/vda2"
log "  rd.verity.hash=/dev/vda3"

exit 0

# Made with Bob
