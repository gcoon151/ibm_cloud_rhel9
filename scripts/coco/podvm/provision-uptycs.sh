#!/bin/bash
# Provision Uptycs OSQuery Agent from initdata
# This script extracts Uptycs configuration from initdata and starts the agent
# Exits gracefully (exit 0) if initdata is missing or Uptycs config is not present

# Don't exit on error - we want to handle errors gracefully
set +e

INITDATA_FILE="/run/peerpod/initdata"
UPTYCS_BIN="/opt/uptycs/bin/osqueryd"

# Target directories (symlinked to /run/osquery/* for dm-verity compatibility)
OSQUERY_ETC="/etc/osquery"
OSQUERY_LOGS="/var/log/osquery"

echo "Starting Uptycs provisioning..."

# Check for required commands
if ! command -v base64 >/dev/null 2>&1; then
    echo "ERROR: base64 command not found (coreutils package missing)"
    exit 0
fi

if ! command -v gzip >/dev/null 2>&1; then
    echo "ERROR: gzip command not found (gzip package missing)"
    exit 0
fi

if ! command -v awk >/dev/null 2>&1; then
    echo "ERROR: awk command not found (gawk package missing)"
    exit 0
fi

echo "All required commands available (base64, gzip, awk)"

# Check if initdata exists
if [ ! -f "$INITDATA_FILE" ]; then
    echo "No initdata file found at $INITDATA_FILE, skipping Uptycs configuration"
    exit 0
fi

# Decode and decompress initdata
echo "Decoding initdata..."
DECODED=$(cat "$INITDATA_FILE" | base64 -d 2>/dev/null | gzip -d 2>/dev/null)

if [ $? -ne 0 ] || [ -z "$DECODED" ]; then
    echo "Failed to decode initdata, skipping Uptycs configuration"
    exit 0
fi

# Extract uptycs.conf section from TOML structure
echo "Extracting Uptycs configuration..."
UPTYCS_CONF=$(echo "$DECODED" | awk '/^"uptycs\.conf" = /,/^'\'\'\''$/ {print}' | sed "1d;\$d")

if [ -z "$UPTYCS_CONF" ]; then
    echo "No Uptycs configuration found in initdata, skipping"
    exit 0
fi

# Write configuration to temporary location
TEMP_CONFIG="/run/peerpod/uptycs.conf"
echo "$UPTYCS_CONF" > "$TEMP_CONFIG"

# Source the configuration
source "$TEMP_CONFIG"

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

# Ensure /etc/osquery directory exists (should be symlink to /run/osquery/etc)
if [ ! -d "$OSQUERY_ETC" ]; then
    echo "ERROR: $OSQUERY_ETC directory does not exist"
    echo "This should have been created as a symlink during image build"
    exit 0
fi

# Create required files in /etc/osquery/
echo "Creating Uptycs configuration files..."

# 1. Create uptycs.secret file
echo "$UPTYCS_SECRET" > "$OSQUERY_ETC/uptycs.secret"
chmod 600 "$OSQUERY_ETC/uptycs.secret"
echo "✓ Created $OSQUERY_ETC/uptycs.secret"

# 2. Create osquery.conf file (empty for now, will be populated by TLS config plugin)
touch "$OSQUERY_ETC/osquery.conf"
chmod 644 "$OSQUERY_ETC/osquery.conf"
echo "✓ Created $OSQUERY_ETC/osquery.conf"

# 3. Create osquery.flags file
# TODO: Get actual flags from EDR team
cat > "$OSQUERY_ETC/osquery.flags" <<EOF
# Uptycs OSQuery Flags
# TODO: Add actual flags provided by EDR team
--tls_hostname=$UPTYCS_BACKEND
--enroll_secret_path=$OSQUERY_ETC/uptycs.secret
--config_plugin=tls
--logger_plugin=tls
--disable_distributed=false
--distributed_plugin=tls
--disable_audit=false
--audit_allow_config=true
--audit_persist=true
--disable_events=false
--disable_tables=false
EOF

# Add tags if specified
if [ -n "$UPTYCS_TAGS" ]; then
    echo "--host_identifier=$UPTYCS_TAGS" >> "$OSQUERY_ETC/osquery.flags"
    # Also create uptycs_tags file
    echo "$UPTYCS_TAGS" > "$OSQUERY_ETC/uptycs_tags"
    echo "✓ Created $OSQUERY_ETC/uptycs_tags"
fi

# Add proxy if specified
if [ -n "$UPTYCS_PROXY" ]; then
    echo "--proxy_hostname=$UPTYCS_PROXY" >> "$OSQUERY_ETC/osquery.flags"
fi

chmod 644 "$OSQUERY_ETC/osquery.flags"
echo "✓ Created $OSQUERY_ETC/osquery.flags"

# 4. Copy CA certificate if it exists
if [ -f /usr/share/osquery/certs/certs.pem ]; then
    cp /usr/share/osquery/certs/certs.pem "$OSQUERY_ETC/ca.crt"
    chmod 644 "$OSQUERY_ETC/ca.crt"
    echo "✓ Copied CA certificate to $OSQUERY_ETC/ca.crt"
fi

# Verify all required files exist
echo ""
echo "Verifying /etc/osquery directory contents:"
ls -la "$OSQUERY_ETC/"
echo ""

# Ensure log directory exists
mkdir -p "$OSQUERY_LOGS"
echo "✓ Log directory ready at $OSQUERY_LOGS"

echo "Uptycs configuration complete"
echo "Starting Uptycs OSQuery agent..."

# Launch Uptycs with new command format
# Using --flagfile and --config_path as specified by EDR team
UPTYCS_CMD="$UPTYCS_BIN --flagfile $OSQUERY_ETC/osquery.flags --config_path $OSQUERY_ETC/osquery.conf"

# Add tags via command line if specified
if [ -n "$UPTYCS_TAGS" ]; then
    UPTYCS_CMD="$UPTYCS_CMD --osquery_tags \"$UPTYCS_TAGS\""
fi

echo "Command: $UPTYCS_CMD"
echo ""
echo "Logs will be written to: $OSQUERY_LOGS/osqueryd.worker.log"
echo ""

# Launch Uptycs in foreground (systemd will manage as daemon)
exec $UPTYCS_CMD

# Made with Bob
