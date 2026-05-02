#!/bin/bash
# Install dm-verity configuration service into the image
# This service runs BEFORE agent-protocol-forwarder to prevent
# cloud-api-adaptor connection loss during reboot

set -euo pipefail

LOG_FILE="/var/log/dmverity-configure-install.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "==========================================
  Installing dm-verity Configuration Service
=========================================="

# Install the configuration script
if [ -f "/tmp/configure-dmverity.sh" ]; then
    log "Installing configuration script..."
    cp /tmp/configure-dmverity.sh /usr/local/sbin/
    chmod +x /usr/local/sbin/configure-dmverity.sh
    log "✓ Installed: /usr/local/sbin/configure-dmverity.sh"
else
    log "ERROR: /tmp/configure-dmverity.sh not found"
    exit 1
fi

# Install the systemd service
if [ -f "/tmp/dmverity-configure.service" ]; then
    log "Installing systemd service..."
    cp /tmp/dmverity-configure.service /etc/systemd/system/
    log "✓ Installed: /etc/systemd/system/dmverity-configure.service"
else
    log "ERROR: /tmp/dmverity-configure.service not found"
    exit 1
fi

# Install grubby if not present
log "Checking for grubby..."
if ! command -v grubby &> /dev/null; then
    log "Installing grubby..."
    dnf install -y grubby || {
        log "ERROR: Failed to install grubby"
        exit 1
    }
    log "✓ Installed grubby"
else
    log "✓ grubby already installed"
fi

# Enable the service
log "Enabling dmverity-configure.service..."
systemctl enable dmverity-configure.service || {
    log "ERROR: Failed to enable service"
    exit 1
}
log "✓ Service enabled"

# Create systemd drop-in for kata-agent to depend on dmverity-configure
log "Creating kata-agent service dependency..."
mkdir -p /etc/systemd/system/kata-agent.service.d
cat > /etc/systemd/system/kata-agent.service.d/10-dmverity.conf <<EOF
[Unit]
# Wait for dm-verity configuration to complete before starting agent
After=dmverity-configure.service
Requires=dmverity-configure.service
EOF
log "✓ Created kata-agent dependency"

# Reload systemd
log "Reloading systemd daemon..."
systemctl daemon-reload
log "✓ Systemd reloaded"

log "==========================================
  Installation Complete
=========================================="

log "Service behavior:"
log "  First boot:"
log "    1. dmverity-configure.service runs"
log "    2. Adds kernel parameters to GRUB"
log "    3. Creates marker file"
log "    4. Reboots system"
log "    5. kata-agent BLOCKED (never starts)"
log "    6. cloud-api-adaptor never connects"
log ""
log "  Second boot:"
log "    1. dm-verity active (kernel parameters present)"
log "    2. dmverity-configure.service sees marker, skips"
log "    3. kata-agent starts normally"
log "    4. cloud-api-adaptor connects"
log "    5. Pod becomes Ready"

exit 0

# Made with Bob
