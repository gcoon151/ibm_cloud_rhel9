#!/bin/bash
# Configure dm-verity kernel parameters for next boot
# This script runs BEFORE agent-protocol-forwarder starts to prevent
# cloud-api-adaptor from connecting before reboot completes

set -euo pipefail

LOG_FILE="/var/log/dmverity-configure.log"
MARKER="/var/lib/dmverity-configured"
ROOTHASH_FILE="/boot/efi/dmverity/roothash.txt"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

log "==========================================
  dm-verity Configuration Service
=========================================="

# Check if already configured
if [ -f "$MARKER" ]; then
    log "✓ dm-verity already configured (marker exists)"
    log "Skipping configuration and reboot"
    exit 0
fi

log "First boot detected - configuring dm-verity..."

# Read roothash from EFI partition
if [ ! -f "$ROOTHASH_FILE" ]; then
    log "ERROR: Roothash file not found: $ROOTHASH_FILE"
    log "dm-verity cannot be enabled without roothash"
    # Create marker anyway to prevent boot loop
    touch "$MARKER"
    exit 1
fi

ROOTHASH=$(cat "$ROOTHASH_FILE" | tr -d '\n' | xargs)

# Validate roothash format
if ! echo "$ROOTHASH" | grep -qE '^[0-9a-f]{64}$'; then
    log "ERROR: Invalid roothash format: $ROOTHASH"
    log "Expected: 64 hexadecimal characters"
    touch "$MARKER"
    exit 1
fi

log "Roothash: ${ROOTHASH:0:16}...${ROOTHASH:48:16}"

# Add kernel parameters via grubby
log "Adding dm-verity kernel parameters to GRUB..."
if grubby --update-kernel=ALL --args="rd.verity.enable=1 rd.verity.roothash=$ROOTHASH rd.verity.data=/dev/vda2 rd.verity.hash=/dev/vda3"; then
    log "✓ Kernel parameters added successfully"
else
    log "ERROR: Failed to add kernel parameters"
    touch "$MARKER"
    exit 1
fi

# Verify parameters were added
log "Verifying kernel parameters..."
if grubby --info=ALL | grep -q "rd.verity.roothash=$ROOTHASH"; then
    log "✓ Kernel parameters verified in GRUB config"
else
    log "WARN: Could not verify kernel parameters in GRUB config"
fi

# Create marker file to prevent re-configuration
touch "$MARKER"
log "✓ Created configuration marker: $MARKER"

log "==========================================
  Configuration Complete - Rebooting
=========================================="

# Trigger reboot
# Note: This happens BEFORE agent-protocol-forwarder starts,
# so cloud-api-adaptor never connects on first boot
systemctl reboot

exit 0

# Made with Bob
