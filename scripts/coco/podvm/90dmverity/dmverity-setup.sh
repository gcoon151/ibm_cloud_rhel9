#!/bin/bash
# dm-verity setup script for initramfs
# Runs BEFORE root filesystem mount
# Priority: 50 (runs in pre-mount phase)

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

LOG_FILE="/run/dmverity/setup.log"
mkdir -p /run/dmverity

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

log "==========================================
  dm-verity Initramfs Setup
=========================================="

# Check if dm-verity is requested
DMVERITY_ENABLED=$(getarg rd.verity.enable)
if [ "$DMVERITY_ENABLED" != "1" ]; then
    log "dm-verity not enabled (rd.verity.enable=1 not set)"
    exit 0
fi

log "dm-verity enabled, proceeding with setup..."

# Get roothash from kernel cmdline (passed via initdata)
ROOTHASH=$(getarg rd.verity.roothash)

# Fallback: Try to read from EFI partition if mounted
if [ -z "$ROOTHASH" ] && [ -f "/boot/efi/dmverity/roothash.txt" ]; then
    ROOTHASH=$(cat /boot/efi/dmverity/roothash.txt | tr -d '\n' | xargs)
    log "Using roothash from EFI partition"
elif [ -n "$ROOTHASH" ]; then
    log "Using roothash from kernel cmdline"
fi

if [ -z "$ROOTHASH" ]; then
    log "ERROR: No roothash found"
    log "  - Kernel cmdline: rd.verity.roothash not set"
    log "  - EFI partition: /boot/efi/dmverity/roothash.txt not found"
    exit 1
fi

# Validate roothash format (64 hex characters)
if ! echo "$ROOTHASH" | grep -qE '^[0-9a-f]{64}$'; then
    log "ERROR: Invalid roothash format: $ROOTHASH"
    log "Expected: 64 hexadecimal characters"
    exit 1
fi

log "Roothash: ${ROOTHASH:0:16}...${ROOTHASH:48:16}"

# Get device parameters
DATA_DEV=$(getarg rd.verity.data)
HASH_DEV=$(getarg rd.verity.hash)

# Default to /dev/vda2 (data) and /dev/vda3 (hash) if not specified
DATA_DEV=${DATA_DEV:-/dev/vda2}
HASH_DEV=${HASH_DEV:-/dev/vda3}

log "Data device: $DATA_DEV"
log "Hash device: $HASH_DEV"

# Wait for devices to be available
log "Waiting for devices..."
for dev in "$DATA_DEV" "$HASH_DEV"; do
    if [ ! -b "$dev" ]; then
        log "ERROR: Device $dev not found"
        exit 1
    fi
done

# Get root partition size
ROOT_SIZE=$(blockdev --getsz "$DATA_DEV")
log "Root partition size: $ROOT_SIZE sectors"

# Create dm-verity device
log "Creating dm-verity device..."
VERITY_TABLE="0 $ROOT_SIZE verity 1 $DATA_DEV $HASH_DEV 4096 4096 655360 1 sha256 $ROOTHASH"

if dmsetup create root-verity --table "$VERITY_TABLE"; then
    log "✓ dm-verity device created successfully"
    
    # Verify device exists
    if [ -b /dev/mapper/root-verity ]; then
        log "✓ /dev/mapper/root-verity exists"
        
        # Update root device for systemd
        # This tells systemd to mount /dev/mapper/root-verity as root instead of /dev/vda2
        echo "root=/dev/mapper/root-verity" > /etc/cmdline.d/99-dmverity.conf
        log "✓ Updated root device to /dev/mapper/root-verity"
        
        # Make root filesystem read-only
        echo "ro" >> /etc/cmdline.d/99-dmverity.conf
        log "✓ Set root filesystem to read-only"
        
        # Enable systemd volatile overlay
        echo "systemd.volatile=overlay" >> /etc/cmdline.d/99-dmverity.conf
        log "✓ Enabled systemd volatile overlay"
        
    else
        log "ERROR: /dev/mapper/root-verity not created"
        exit 1
    fi
else
    log "ERROR: Failed to create dm-verity device"
    dmsetup status 2>&1 | tee -a "$LOG_FILE"
    exit 1
fi

log "dm-verity setup complete"
exit 0

# Made with Bob
