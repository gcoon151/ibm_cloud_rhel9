#!/bin/bash
# Inline Uptycs installation script with logging
# This script runs inside the VM during virt-customize
# All files are in /tmp/ (copied by virt-customize --copy-in)

set -euxo pipefail

LOGFILE="/var/log/uptycs-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ""
echo "=========================================="
echo "=== Installing Uptycs EDR Agent ==="
echo "=== $(date) ==="
echo "=========================================="
echo ""

# List files in /tmp to verify they were copied
echo "Files in /tmp:"
ls -lh /tmp/ | grep -E "(uptycs|provision)" || echo "No Uptycs files found!"
echo ""

# Check if Uptycs binary tarball exists (copied to /tmp/ by virt-customize)
if [ ! -f /tmp/uptycs-binary.tar.gz ]; then
    echo "ERROR: uptycs-binary.tar.gz not found at /tmp/"
    echo "This file should be copied by virt-customize during build"
    echo "Available files in /tmp:"
    ls -la /tmp/
    exit 1
fi

echo "✓ Found uptycs-binary.tar.gz"

# Extract Uptycs binary to /opt/uptycs
echo "Extracting Uptycs binary to /opt/uptycs..."
mkdir -p /opt/uptycs
tar -xzf /tmp/uptycs-binary.tar.gz -C /opt/uptycs
echo "✓ Extraction complete"
echo ""

# Verify binary exists and is executable
echo "Verifying osqueryd binary..."
if [ ! -f /opt/uptycs/bin/osqueryd ]; then
    echo "ERROR: osqueryd binary not found after extraction"
    echo "Contents of /opt/uptycs:"
    find /opt/uptycs -type f
    exit 1
fi

chmod +x /opt/uptycs/bin/osqueryd
echo "✓ Binary is executable"

# Verify it's a valid ELF binary
echo "Binary info:"
file /opt/uptycs/bin/osqueryd
ls -lh /opt/uptycs/bin/osqueryd
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

echo "=========================================="
echo "=== Uptycs Installation Complete ==="
echo "=========================================="
echo ""
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

# Made with Bob

# Made with Bob
