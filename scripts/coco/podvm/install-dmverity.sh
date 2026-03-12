#!/bin/bash
# Install dm-verity service into PodVM image
# This script runs during virt-customize (image build time)

set -e

# Log to file for debugging
LOGFILE="/var/log/dmverity-install.log"
exec >> "$LOGFILE" 2>&1

echo ""
echo "=========================================="
echo "=== Installing dm-verity Service ==="
echo "=== $(date) ==="
echo "=========================================="
echo ""

# Check if dm-verity service files exist (copied to /tmp/ by virt-customize)
if [ ! -f /tmp/apply-dmverity.service ] || [ ! -f /tmp/apply-dmverity.sh ]; then
    echo "⚠ dm-verity service files not found in /tmp/"
    echo "  This is normal if dm-verity is not being used"
    echo "  Skipping dm-verity installation"
    exit 0
fi

echo "✓ Found dm-verity service files"
echo ""

# Install the service
echo "Installing apply-dmverity.service..."
cp /tmp/apply-dmverity.service /etc/systemd/system/
chmod 644 /etc/systemd/system/apply-dmverity.service
echo "✓ Service file installed to /etc/systemd/system/"

# Install the script
echo "Installing apply-dmverity.sh..."
mkdir -p /usr/local/sbin
cp /tmp/apply-dmverity.sh /usr/local/sbin/
chmod 755 /usr/local/sbin/apply-dmverity.sh
echo "✓ Script installed to /usr/local/sbin/"

# Enable the service
echo "Enabling apply-dmverity.service..."
systemctl enable apply-dmverity.service
echo "✓ Service enabled"

echo ""
echo "=========================================="
echo "=== dm-verity Service Installation Complete ==="
echo "=========================================="
echo ""
echo "Service will activate at boot and apply dm-verity protection"
echo "Roothash sources (priority order):"
echo "  1. Trustee sealed secret (/run/trustee/roothash)"
echo "  2. Kernel cmdline (initdata)"
echo "  3. EFI partition (/boot/efi/dmverity/roothash.txt)"
echo "  4. Fallback (/etc/dmverity/roothash.txt)"
echo ""

# Verify installation
echo "Verifying installation:"
ls -la /etc/systemd/system/apply-dmverity.service
ls -la /usr/local/sbin/apply-dmverity.sh
systemctl is-enabled apply-dmverity.service || true
echo ""

echo "✓ dm-verity service installation complete"

# Made with Bob
