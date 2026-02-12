#!/bin/bash
# Install kata-agent metrics configuration
# This script runs during virt-customize (image build time)

set -euxo pipefail

echo ""
echo "=========================================="
echo "=== Installing kata-agent metrics config ==="
echo "=== $(date) ==="
echo "=========================================="
echo ""

# Check if metrics config exists (copied to /tmp/ by virt-customize)
if [ ! -f /tmp/20-enable-metrics.conf ]; then
    echo "ERROR: 20-enable-metrics.conf not found at /tmp/"
    echo "This file should be copied by virt-customize during build"
    echo "Available files in /tmp:"
    ls -la /tmp/
    exit 1
fi

echo "✓ Found 20-enable-metrics.conf"

# Install the metrics configuration
echo "Installing kata-agent metrics configuration..."
mkdir -p /etc/systemd/system/kata-agent.service.d
cp /tmp/20-enable-metrics.conf /etc/systemd/system/kata-agent.service.d/
chmod 644 /etc/systemd/system/kata-agent.service.d/20-enable-metrics.conf

echo "✓ Metrics configuration installed"
echo ""

echo "=========================================="
echo "=== Metrics Config Installation Complete ==="
echo "=========================================="
echo ""
echo "Installed components:"
echo "  - Metrics config: /etc/systemd/system/kata-agent.service.d/20-enable-metrics.conf"
echo ""
echo "kata-agent will start with metrics enabled on port 8090"
echo ""

# Made with Bob