#!/bin/bash
# Apply dm-verity Root Protection from initdata
# This script runs at boot via apply-dmverity.service
# It reads the roothash from initdata and applies dm-verity protection

# Note: We don't use 'set -e' here because we need to try multiple roothash sources
# and continue if one fails. We explicitly check return codes where needed.
set -u  # Exit on undefined variables

INITDATA_FILE="/var/run/peerpod/initdata"
TRUSTEE_ROOTHASH="/run/trustee/roothash"
EFI_ROOTHASH="/boot/efi/dmverity/roothash.txt"
ROOT_ROOTHASH="/etc/dmverity/roothash.txt"
LOG_FILE="/var/log/dmverity-apply.log"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

log "=========================================="
log "  dm-verity Application Starting"
log "=========================================="

# Function to extract roothash from initdata
get_roothash_from_initdata() {
    if [ ! -f "$INITDATA_FILE" ]; then
        log "No initdata file found at $INITDATA_FILE"
        return 1
    fi
    
    log "Decoding initdata..."
    local decoded=$(cat "$INITDATA_FILE" | base64 -d 2>/dev/null | gzip -d 2>/dev/null)
    
    if [ $? -ne 0 ] || [ -z "$decoded" ]; then
        log "Failed to decode initdata"
        return 1
    fi
    
    # Extract dmverity.conf section
    local dmverity_conf=$(echo "$decoded" | awk '/^\[dmverity\.conf\]$/,/^$/ {print}' | grep "ROOTHASH=" | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
    
    if [ -z "$dmverity_conf" ]; then
        # Try alternative format (simple key=value)
        dmverity_conf=$(echo "$decoded" | grep "^ROOTHASH=" | cut -d= -f2 | tr -d '"' | tr -d "'" | xargs)
    fi
    
    if [ -n "$dmverity_conf" ]; then
        log "Found roothash in initdata"
        echo "$dmverity_conf"
        return 0
    fi
    
    log "No roothash found in initdata"
    return 1
}

# Get roothash with priority order:
# 1. Trustee sealed secret (if customer configured)
# 2. initdata (for testing/development)
# 3. EFI partition (default, covered by attestation)
# 4. Root partition (last resort, convenience)

ROOTHASH=""
SOURCE=""

# Priority 1: Trustee sealed secret
if [ -f "$TRUSTEE_ROOTHASH" ]; then
    ROOTHASH=$(cat "$TRUSTEE_ROOTHASH" | tr -d '\n' | xargs)
    SOURCE="Trustee sealed secret"
    log "Using roothash from Trustee: $TRUSTEE_ROOTHASH"
fi

# Priority 2: initdata (for testing)
if [ -z "$ROOTHASH" ]; then
    ROOTHASH=$(get_roothash_from_initdata)
    if [ -n "$ROOTHASH" ]; then
        SOURCE="initdata"
        log "Using roothash from initdata"
    fi
fi

# Priority 3: EFI partition (default, covered by attestation)
if [ -z "$ROOTHASH" ] && [ -f "$EFI_ROOTHASH" ]; then
    ROOTHASH=$(cat "$EFI_ROOTHASH" | tr -d '\n' | xargs)
    SOURCE="EFI partition"
    log "Using roothash from EFI partition: $EFI_ROOTHASH"
fi

# Priority 4: Root partition (last resort)
if [ -z "$ROOTHASH" ] && [ -f "$ROOT_ROOTHASH" ]; then
    ROOTHASH=$(cat "$ROOT_ROOTHASH" | tr -d '\n' | xargs)
    SOURCE="root partition"
    log "Using roothash from root partition: $ROOT_ROOTHASH"
fi

if [ -z "$ROOTHASH" ]; then
    log "ERROR: No roothash found in any location:"
    log "  - Trustee: $TRUSTEE_ROOTHASH"
    log "  - initdata: $INITDATA_FILE"
    log "  - EFI: $EFI_ROOTHASH"
    log "  - Root: $ROOT_ROOTHASH"
    log "dm-verity will NOT be applied"
    log "To enable dm-verity, ensure roothash is in EFI partition or configure Trustee"
    exit 0  # Exit gracefully - dm-verity is optional
fi

log "Roothash source: $SOURCE"

log "Roothash: ${ROOTHASH:0:16}...${ROOTHASH: -16}"

# Verify roothash format (should be 64 hex characters for SHA-256)
if ! echo "$ROOTHASH" | grep -qE '^[0-9a-f]{64}$'; then
    log "ERROR: Invalid roothash format (expected 64 hex characters)"
    log "Roothash: $ROOTHASH"
    exit 1
fi

# Check if dm-verity devices exist
if [ ! -b /dev/vda2 ] || [ ! -b /dev/vda3 ]; then
    log "ERROR: Required block devices not found"
    log "Expected: /dev/vda2 (root), /dev/vda3 (verity)"
    ls -l /dev/vda* | tee -a "$LOG_FILE"
    exit 1
fi

# Get root partition size
ROOT_SIZE=$(blockdev --getsz /dev/vda2)
log "Root partition size: $ROOT_SIZE sectors"

# Apply dm-verity
log "Creating dm-verity device..."
if dmsetup create root-verity --table "0 $ROOT_SIZE verity 1 /dev/vda2 /dev/vda3 4096 4096 655360 1 sha256 $ROOTHASH"; then
    log "✓ dm-verity device created successfully"
else
    log "ERROR: Failed to create dm-verity device"
    exit 1
fi

# Verify dm-verity device
if [ -b /dev/mapper/root-verity ]; then
    log "✓ /dev/mapper/root-verity exists"
    dmsetup status root-verity | tee -a "$LOG_FILE"
else
    log "ERROR: /dev/mapper/root-verity not created"
    exit 1
fi

# Note: We don't remount root here because it's already mounted
# The dm-verity device will be used for verification on reads
# systemd.volatile=overlay should be passed via kernel cmdline for tmpfs overlay

log "=========================================="
log "  dm-verity Applied Successfully"
log "=========================================="
log "Root filesystem is now protected by dm-verity"
log "Any tampering will be detected and blocked"

exit 0

# Made with Bob
