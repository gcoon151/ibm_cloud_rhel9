#!/bin/bash
# Install Uptycs EDR agent into PodVM image
# This script runs INSIDE the QCOW2 VM via virt-customize
# Output goes to virt-customize stdout which the container captures

# Enable debug mode - show every command as it executes
set -x

# Exit on any error
set -e

# Log file for post-build inspection (saved in the QCOW2 image)
LOGFILE="/var/log/uptycs-install.log"

# Check if tee is available
if command -v tee >/dev/null 2>&1; then
    HAS_TEE=true
    echo "tee is available, will log to both stdout and $LOGFILE"
else
    HAS_TEE=false
    echo "tee not available, logging to stdout only"
fi

# Logging function that uses tee if available, otherwise just echo
log() {
    if [ "$HAS_TEE" = true ]; then
        echo "$@" | tee -a "$LOGFILE"
    else
        echo "$@"
        echo "$@" >> "$LOGFILE"
    fi
}

log "=========================================="
log "UPTYCS INSTALL START: $(date)"
log "Running from: $(pwd)"
log "User: $(whoami)"
log "=========================================="

# Create marker file immediately to prove script started
echo "[STEP 1/10] Creating start marker..."
touch /UPTYCS_INSTALL_STARTED
echo "✓ Start marker created"

# List files in /tmp to verify they were copied
echo "[STEP 2/10] Verifying files in /tmp..."
ls -lh /tmp/ | grep -E "(uptycs|provision)" || true
echo ""

# Check if Uptycs complete tarball exists (copied to /tmp/ by virt-customize)
echo "[STEP 3/10] Checking for Uptycs tarball..."
if [ ! -f /tmp/uptycs-complete.tar.gz ]; then
    echo "✗ ERROR: uptycs-complete.tar.gz not found at /tmp/"
    echo "This file should be copied by virt-customize during build"
    echo "Available files in /tmp:"
    ls -la /tmp/
    exit 1
fi
echo "✓ Found uptycs-complete.tar.gz"

# Extract to temporary location first
echo "[STEP 4/10] Extracting Uptycs package..."
TEMP_EXTRACT="/tmp/uptycs-extracted"
mkdir -p "$TEMP_EXTRACT"
tar -xzf /tmp/uptycs-complete.tar.gz -C "$TEMP_EXTRACT" --exclude='._*'
echo "✓ Extraction complete"
echo ""

# Debug: Show what was extracted
echo "[STEP 5/10] Verifying extracted contents..."
find "$TEMP_EXTRACT" -type f | sort
echo ""

# Install binaries to /usr/bin/ (where Uptycs expects them)
echo "[STEP 6/10] Installing Uptycs binaries to /usr/bin/..."
REQUIRED_BINARIES=(
    "osqueryd"
    "uptycs-protect"
    "uptycs-nft"
    "bpf_progs.o"
    "uptycs_audit_conf.sh"
)

for binary in "${REQUIRED_BINARIES[@]}"; do
    if [ ! -f "$TEMP_EXTRACT/bin/$binary" ]; then
        echo "✗ ERROR: $binary not found in extracted package"
        exit 1
    fi
    
    # Copy to /usr/bin/
    cp "$TEMP_EXTRACT/bin/$binary" "/usr/bin/$binary"
    
    # Set permissions
    if [[ "$binary" == *.o ]]; then
        # bpf_progs.o is a data file
        chmod 644 "/usr/bin/$binary"
    else
        # Executables
        chmod 755 "/usr/bin/$binary"
    fi
    
    chown root:root "/usr/bin/$binary"
    echo "  ✓ Installed $binary to /usr/bin/"
done
echo "✓ All binaries installed successfully"
echo ""

# Verify binaries
echo "[STEP 7/10] Verifying installed binaries..."
file /usr/bin/osqueryd
file /usr/bin/uptycs-protect
file /usr/bin/uptycs-nft
ls -lh /usr/bin/osqueryd /usr/bin/uptycs-protect /usr/bin/uptycs-nft /usr/bin/bpf_progs.o /usr/bin/uptycs_audit_conf.sh
echo "✓ Binary verification complete"
echo ""

# Install CA certificate for TLS verification
echo "[STEP 8/10] Installing CA certificate..."
if [ -f "$TEMP_EXTRACT/etc/osquery/cert/ca.crt" ]; then
    # Create a temporary location for the cert (will be copied to /etc/osquery at runtime)
    mkdir -p /usr/share/osquery/certs
    cp "$TEMP_EXTRACT/etc/osquery/cert/ca.crt" /usr/share/osquery/certs/ca.crt
    chmod 644 /usr/share/osquery/certs/ca.crt
    echo "✓ CA certificate installed to /usr/share/osquery/certs/ca.crt"
    echo "  (will be copied to /etc/osquery/ca.crt at runtime)"
else
    echo "⚠ WARNING: CA certificate not found in extracted package"
    echo "TLS enrollment may fail without proper certificates"
fi
echo ""

# Clean up temporary extraction
echo "[STEP 9/10] Cleaning up temporary files..."
rm -rf "$TEMP_EXTRACT"
echo "✓ Cleanup complete"
echo ""

# Create symlinks for /etc/osquery, /var/log/osquery, and /var/osquery to tmpfs locations
# This must happen BEFORE dm-verity signing
# Structure mirrors the original Uptycs installation paths under /var/run/osquery/
echo "[STEP 10/10] Creating symlinks for dm-verity compatibility..."

# Note: The actual directories will be created at runtime by provision-uptycs.sh
# We only create the symlinks here during image build

# Create /etc/osquery as symlink to /var/run/osquery/etc/osquery/
if [ -d /etc/osquery ]; then
    echo "⚠ WARNING: /etc/osquery already exists, removing..."
    rm -rf /etc/osquery
fi
ln -s /var/run/osquery/etc/osquery /etc/osquery
echo "  ✓ Created symlink: /etc/osquery -> /var/run/osquery/etc/osquery"

# Create /var/log/osquery as symlink to /var/run/osquery/var/log/osquery/
mkdir -p /var/log
if [ -d /var/log/osquery ]; then
    echo "⚠ WARNING: /var/log/osquery already exists, removing..."
    rm -rf /var/log/osquery
fi
ln -s /var/run/osquery/var/log/osquery /var/log/osquery
echo "  ✓ Created symlink: /var/log/osquery -> /var/run/osquery/var/log/osquery"

# Create /var/osquery as symlink to /var/run/osquery/var/osquery/ (for database)
mkdir -p /var
if [ -d /var/osquery ]; then
    echo "⚠ WARNING: /var/osquery already exists, removing..."
    rm -rf /var/osquery
fi
ln -s /var/run/osquery/var/osquery /var/osquery
echo "  ✓ Created symlink: /var/osquery -> /var/run/osquery/var/osquery"

# Verify symlinks
echo "Verifying symlinks:"
ls -la /etc/osquery
ls -la /var/log/osquery
ls -la /var/osquery
echo "✓ Symlinks created successfully"
echo ""

# Install the provisioning script that will run at boot
echo "[STEP 11/12] Installing provisioning script..."
if [ -f /tmp/provision-uptycs.sh ]; then
    mkdir -p /usr/local/bin
    cp /tmp/provision-uptycs.sh /usr/local/bin/
    chmod 755 /usr/local/bin/provision-uptycs.sh
    echo "✓ Provisioning script installed to /usr/local/bin/provision-uptycs.sh"
else
    echo "✗ ERROR: provision-uptycs.sh not found at /tmp/"
    exit 1
fi
echo ""

# Install the systemd service that will run the provisioning script at boot
echo "[STEP 12/12] Installing systemd service..."
if [ -f /tmp/uptycs-osquery.service ]; then
    cp /tmp/uptycs-osquery.service /etc/systemd/system/
    chmod 644 /etc/systemd/system/uptycs-osquery.service
    
    # Enable the service (will only start if initdata exists at boot)
    echo "Enabling uptycs-osquery.service..."
    systemctl enable uptycs-osquery.service
    
    echo "✓ Systemd service installed and enabled"
else
    echo "✗ ERROR: uptycs-osquery.service not found at /tmp/"
    exit 1
fi
echo ""

# Set system-wide ulimit for file descriptors
echo "[STEP 13/13] Configuring system ulimits..."
cat >> /etc/security/limits.conf << 'EOF'
# Uptycs EDR requires high file descriptor limits
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

# Also set in systemd system.conf for services
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/uptycs-limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

echo "✓ System ulimits configured (nofile=1048576)"
echo ""

echo "=========================================="
echo "=== ✓ Uptycs Installation Complete ==="
echo "=========================================="
echo ""
echo "Installed components:"
echo "  - Binaries in /usr/bin/:"
echo "    • osqueryd"
echo "    • uptycs-protect"
echo "    • uptycs-nft"
echo "    • bpf_progs.o"
echo "    • uptycs_audit_conf.sh"
echo "  - Certificate: /usr/share/osquery/certs/ca.crt"
echo "  - Provisioning script: /usr/local/bin/provision-uptycs.sh"
echo "  - Systemd service: /etc/systemd/system/uptycs-osquery.service (enabled)"
echo "  - Symlinks created for dm-verity compatibility"
echo ""
echo "At runtime, the service will:"
echo "  1. Check for /var/run/peerpod/initdata"
echo "  2. Extract Uptycs configuration from initdata"
echo "  3. Start osqueryd with the extracted config"
echo ""
echo "Full installation log saved to: $LOGFILE"
echo ""

# Create success marker with timestamp
echo "[FINAL] Creating success marker..."
touch /UPTYCS_INSTALL_SUCCESS
echo "Installation completed successfully at $(date)" >> /UPTYCS_INSTALL_SUCCESS
echo "✓ Success marker created at /UPTYCS_INSTALL_SUCCESS"
echo ""
echo "🎉 ALL STEPS COMPLETED SUCCESSFULLY 🎉"