#!/bin/bash
# Install Uptycs EDR agent into PodVM image
# This script runs during virt-customize (image build time)
# It installs the Uptycs binary and sets up the systemd service

set -e

# Create marker file immediately to prove script started
touch /UPTYCS_INSTALL_STARTED

# Log to file for debugging
LOGFILE="/var/log/uptycs-install.log"
exec >> "$LOGFILE" 2>&1

echo ""
echo "=========================================="
echo "=== Installing Uptycs EDR Agent ==="
echo "=== $(date) ==="
echo "=========================================="
echo ""

# Update marker
echo "Script logging initialized" > /UPTYCS_INSTALL_STARTED

# List files in /tmp to verify they were copied
echo "Files in /tmp:"
ls -lh /tmp/ | grep -E "(uptycs|provision)" || true
echo ""

# Check if Uptycs complete tarball exists (copied to /tmp/ by virt-customize)
if [ ! -f /tmp/uptycs-complete.tar.gz ]; then
    echo "ERROR: uptycs-complete.tar.gz not found at /tmp/"
    echo "This file should be copied by virt-customize during build"
    echo "Available files in /tmp:"
    ls -la /tmp/
    exit 1
fi

echo "✓ Found uptycs-complete.tar.gz"

# Extract to temporary location first
echo "Extracting Uptycs complete package..."
TEMP_EXTRACT="/tmp/uptycs-extracted"
mkdir -p "$TEMP_EXTRACT"
tar -xzf /tmp/uptycs-complete.tar.gz -C "$TEMP_EXTRACT" --exclude='._*'
echo "✓ Extraction complete"
echo ""

# Debug: Show what was extracted
echo "Contents of extracted package:"
find "$TEMP_EXTRACT" -type f | sort
echo ""

# Install binaries to /usr/bin/ (where Uptycs expects them)
echo "Installing Uptycs binaries to /usr/bin/..."
REQUIRED_BINARIES=(
    "osqueryd"
    "uptycs-protect"
    "uptycs-nft"
    "bpf_progs.o"
    "uptycs_audit_conf.sh"
)

for binary in "${REQUIRED_BINARIES[@]}"; do
    if [ ! -f "$TEMP_EXTRACT/bin/$binary" ]; then
        echo "ERROR: $binary not found in extracted package"
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
echo ""

# Verify binaries
echo "Verifying installed binaries:"
file /usr/bin/osqueryd
file /usr/bin/uptycs-protect
file /usr/bin/uptycs-nft
ls -lh /usr/bin/osqueryd /usr/bin/uptycs-protect /usr/bin/uptycs-nft /usr/bin/bpf_progs.o /usr/bin/uptycs_audit_conf.sh
echo ""

# Install CA certificate for TLS verification
echo "Installing CA certificate..."
if [ -f "$TEMP_EXTRACT/etc/osquery/cert/ca.crt" ]; then
    # Create a temporary location for the cert (will be copied to /etc/osquery at runtime)
    mkdir -p /usr/share/osquery/certs
    cp "$TEMP_EXTRACT/etc/osquery/cert/ca.crt" /usr/share/osquery/certs/ca.crt
    chmod 644 /usr/share/osquery/certs/ca.crt
    echo "✓ CA certificate installed to /usr/share/osquery/certs/ca.crt"
    echo "  (will be copied to /etc/osquery/ca.crt at runtime)"
else
    echo "WARNING: CA certificate not found in extracted package"
    echo "TLS enrollment may fail without proper certificates"
fi
echo ""

# Clean up temporary extraction
rm -rf "$TEMP_EXTRACT"

# Create symlinks for /etc/osquery, /var/log/osquery, and /var/osquery to tmpfs locations
# This must happen BEFORE dm-verity signing
# Structure mirrors the original Uptycs installation paths under /var/run/osquery/
echo "Creating symlinks for dm-verity compatibility..."

# Note: The actual directories will be created at runtime by provision-uptycs.sh
# We only create the symlinks here during image build

# Create /etc/osquery as symlink to /var/run/osquery/etc/osquery/
if [ -d /etc/osquery ]; then
    echo "WARNING: /etc/osquery already exists, removing..."
    rm -rf /etc/osquery
fi
ln -s /var/run/osquery/etc/osquery /etc/osquery
echo "✓ Created symlink: /etc/osquery -> /var/run/osquery/etc/osquery"

# Create /var/log/osquery as symlink to /var/run/osquery/var/log/osquery/
mkdir -p /var/log
if [ -d /var/log/osquery ]; then
    echo "WARNING: /var/log/osquery already exists, removing..."
    rm -rf /var/log/osquery
fi
ln -s /var/run/osquery/var/log/osquery /var/log/osquery
echo "✓ Created symlink: /var/log/osquery -> /var/run/osquery/var/log/osquery"

# Create /var/osquery as symlink to /var/run/osquery/var/osquery/ (for database)
mkdir -p /var
if [ -d /var/osquery ]; then
    echo "WARNING: /var/osquery already exists, removing..."
    rm -rf /var/osquery
fi
ln -s /var/run/osquery/var/osquery /var/osquery
echo "✓ Created symlink: /var/osquery -> /var/run/osquery/var/osquery"

# Verify symlinks
echo "Verifying symlinks:"
ls -la /etc/osquery
ls -la /var/log/osquery
ls -la /var/osquery
echo ""

# Install the provisioning script that will run at boot
echo "Installing provisioning script..."
if [ -f /tmp/provision-uptycs.sh ]; then
    mkdir -p /usr/local/bin
    cp /tmp/provision-uptycs.sh /usr/local/bin/
    chmod 755 /usr/local/bin/provision-uptycs.sh
    echo "✓ Provisioning script installed to /usr/local/bin/provision-uptycs.sh"
else
    echo "ERROR: provision-uptycs.sh not found at /tmp/"
    exit 1
fi
echo ""

# Install the systemd service that will run the provisioning script at boot
echo "Installing systemd service..."
if [ -f /tmp/uptycs-osquery.service ]; then
    cp /tmp/uptycs-osquery.service /etc/systemd/system/
    chmod 644 /etc/systemd/system/uptycs-osquery.service
    
    # Enable the service (will only start if initdata exists at boot)
    echo "Enabling uptycs-osquery.service..."
    systemctl enable uptycs-osquery.service
    
    echo "✓ Systemd service installed and enabled"
else
    echo "ERROR: uptycs-osquery.service not found at /tmp/"
    exit 1
fi
echo ""

# Set system-wide ulimit for file descriptors
echo "Configuring system ulimits..."
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
echo "=== Uptycs Installation Complete ==="
echo "=========================================="
echo ""
echo "Installed components:"
echo "  - Binaries in /usr/bin/:"
echo "    • osqueryd"
echo "    • uptycs-protect"
echo "    • uptycs-nft"
echo "    • bpf_progs.o"
echo "    • uptycs_audit_conf.sh"
echo "  - Certificate: /etc/osquery/cert/ca.crt"
echo "  - Provisioning script: /usr/local/bin/provision-uptycs.sh"
echo "  - Systemd service: /etc/systemd/system/uptycs-osquery.service (enabled)"
echo ""
echo "At runtime, the service will:"
echo "  1. Check for /var/run/peerpod/initdata"
echo "  2. Extract Uptycs configuration from initdata"
echo "  3. Start osqueryd with the extracted config"
echo ""
echo "Full installation log saved to: $LOGFILE"
echo ""

# Create success marker
echo "Installation completed successfully at $(date)" > /UPTYCS_INSTALL_SUCCESS
echo "Installed components:"
echo "  - Binary: /opt/uptycs/bin/osqueryd"
echo "  - Provisioning script: /usr/local/bin/provision-uptycs.sh"
echo "  - Systemd service: /etc/systemd/system/uptycs-osquery.service (enabled)"
echo ""
echo "At runtime, the service will:"
echo "  1. Check for /var/run/peerpod/initdata"
echo "  2. Extract Uptycs configuration from initdata"
echo "  3. Start osqueryd with the extracted config"
echo ""
echo "Full installation log saved to: $LOGFILE"
echo ""