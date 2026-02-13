#!/bin/bash
# Provision Uptycs OSQuery Agent from initdata
# This script extracts Uptycs configuration from initdata and starts the agent if config is present
# Exits gracefully (exit 0) if initdata is missing or Uptycs config is not present

# Don't exit on error - we want to handle errors gracefully
# set -e removed for RHEL 9.7 compatibility

INITDATA_FILE="/var/run/peerpod/initdata"
UPTYCS_CONFIG="/var/run/peerpod/uptycs.conf"
UPTYCS_BIN="/opt/uptycs/bin/osqueryd"

echo "Starting Uptycs provisioning..."

# Check for required commands
if ! command -v base64 >/dev/null 2>&1; then
    echo "ERROR: base64 command not found (coreutils package missing)"
    echo "Uptycs provisioning cannot proceed without base64"
    exit 0
fi

if ! command -v gzip >/dev/null 2>&1; then
    echo "ERROR: gzip command not found (gzip package missing)"
    echo "Uptycs provisioning cannot proceed without gzip"
    exit 0
fi

if ! command -v awk >/dev/null 2>&1; then
    echo "ERROR: awk command not found (gawk package missing)"
    echo "Uptycs provisioning cannot proceed without awk"
    exit 0
fi

echo "All required commands available (base64, gzip, awk)"

# Check if initdata exists
if [ ! -f "$INITDATA_FILE" ]; then
    echo "No initdata file found at $INITDATA_FILE, skipping Uptycs configuration"
    exit 0
fi

# Decode and decompress initdata
# RHEL 9.7 includes: coreutils (base64), gzip
echo "Decoding initdata..."
DECODED=$(cat "$INITDATA_FILE" | base64 -d 2>/dev/null | gzip -d 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$DECODED" ]; then
    echo "Failed to decode initdata, skipping Uptycs configuration"
    exit 0
fi

# Extract uptycs.conf section from TOML structure
# Looking for: "uptycs.conf" = '''...'''
echo "Extracting Uptycs configuration..."
UPTYCS_CONF=$(echo "$DECODED" | awk '/^"uptycs\.conf" = /,/^'\'\'\''$/ {print}' | sed "1d;\$d")

if [ -z "$UPTYCS_CONF" ]; then
    echo "No Uptycs configuration found in initdata, skipping"
    exit 0
fi

# Write configuration to ephemeral location (dm-verity safe)
echo "Writing Uptycs configuration to $UPTYCS_CONFIG..."
# /var/run/peerpod already exists (created by process-user-data.service)
echo "$UPTYCS_CONF" > "$UPTYCS_CONFIG"

# Source the configuration
source "$UPTYCS_CONFIG"

# Verify required variables
if [ -z "$UPTYCS_SECRET" ]; then
    echo "ERROR: UPTYCS_SECRET not found in configuration"
    exit 0
fi

if [ -z "$UPTYCS_BACKEND" ]; then
    echo "ERROR: UPTYCS_BACKEND not found in configuration"
    exit 0
fi

# Check if Uptycs binary exists
if [ ! -f "$UPTYCS_BIN" ]; then
    echo "ERROR: Uptycs binary not found at $UPTYCS_BIN"
    exit 0
fi

# Create Uptycs data directories on tmpfs (dm-verity safe)
# Using /tmp for database and logs (ephemeral, writable with dm-verity)
UPTYCS_DATA_DIR="/tmp/uptycs"
mkdir -p "$UPTYCS_DATA_DIR"/{db,logs}
echo "Created Uptycs data directories at $UPTYCS_DATA_DIR"

# Write enrollment secret to file (osqueryd expects --enroll_secret_path)
ENROLL_SECRET_FILE="/var/run/peerpod/enroll.secret"
echo "$UPTYCS_SECRET" > "$ENROLL_SECRET_FILE"
chmod 600 "$ENROLL_SECRET_FILE"

# Build command with correct Uptycs osqueryd flags
# Using tmpfs storage paths (dm-verity compatible)
# Core required flags only (no debug flags for production)
UPTYCS_CMD="$UPTYCS_BIN -D --disable_watchdog"
UPTYCS_CMD="$UPTYCS_CMD --database_path=\"$UPTYCS_DATA_DIR/db\""
UPTYCS_CMD="$UPTYCS_CMD --logger_path=\"$UPTYCS_DATA_DIR/logs\""
UPTYCS_CMD="$UPTYCS_CMD --enroll_secret_path=\"$ENROLL_SECRET_FILE\""

# Add backend/server
if [ -n "$UPTYCS_BACKEND" ]; then
    UPTYCS_CMD="$UPTYCS_CMD --tls_hostname=\"$UPTYCS_BACKEND\""
fi

# Add tags if specified (using host_identifier)
if [ -n "$UPTYCS_TAGS" ]; then
    UPTYCS_CMD="$UPTYCS_CMD --host_identifier=\"$UPTYCS_TAGS\""
fi

# Add proxy if specified
if [ -n "$UPTYCS_PROXY" ]; then
    UPTYCS_CMD="$UPTYCS_CMD --proxy_hostname=\"$UPTYCS_PROXY\""
fi

echo "Uptycs configuration extracted successfully"
echo "Starting Uptycs OSQuery agent..."
echo "Command: $UPTYCS_CMD"

# Launch Uptycs in background (no -D flag, using & instead)
eval "$UPTYCS_CMD" &

echo "Uptycs provisioning completed successfully"

# Made with Bob
