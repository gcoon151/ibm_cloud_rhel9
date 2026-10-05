#! /bin/bash

dnf config-manager --add-repo=https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/ && dnf install -y --nogpgcheck e2fsprogs && dnf clean all && dnf config-manager --set-disabled "*centos*"

tar -xzvf /tmp/podvm-binaries.tar.gz -C /
tar -xzvf /tmp/pause-bundle.tar.gz -C /

# Patch agent-config.toml: Red Hat's payload ships with guest_components_procs = "none"
# which breaks the AA→CDH→kata-agent activation chain (kata-agent.path waits for
# cdh.sock, which CDH only creates when AA runs first; with "none" AA never starts
# via kata-agent's internal launcher and the chain stalls).
# The correct value for IBM Cloud CoCo peer pods is "confidential_data_hub" — this
# makes kata-agent launch AA and CDH as sub-processes at startup.
echo "Patching agent-config.toml..."
sed -i 's/guest_components_procs = "none"/guest_components_procs = "confidential_data_hub"/' /etc/agent-config.toml
echo "✓ Set guest_components_procs = confidential_data_hub"
if ! grep -q "image_registry_auth" /etc/agent-config.toml; then
    echo 'image_registry_auth = "file:///run/peerpod/auth.json"' >> /etc/agent-config.toml
    echo "✓ Added image_registry_auth to agent-config.toml"
else
    echo "✓ image_registry_auth already present in agent-config.toml"
fi
# NOTE: enable_signature_verification is intentionally NOT baked into the image.
# When baked in, it causes CreateSandbox to fail with the nosigning initdata
# because kata-agent tries to fetch the image policy from KBS before the container
# starts, and KBS attestation fails in that context. The signing config is
# applied at the cluster level via initdata when signature verification is needed.

# set luks
# TODO: move to payload ?
tar -xzvf /tmp/luks-config.tar.gz -C /

# fixes a failure of the podns@netns service
semanage fcontext -a -t bin_t /usr/sbin/ip && restorecon -v /usr/sbin/ip

# Fix SELinux context for kata-agent binaries
semanage fcontext -a -t bin_t /usr/local/bin/kata-agent && restorecon -v /usr/local/bin/kata-agent
semanage fcontext -a -t bin_t /usr/local/bin/kata-agent-clean && restorecon -v /usr/local/bin/kata-agent-clean

# Configure SSHD service - PLACEHOLDER will be replaced by remote-build.sh
BUILD_LOG="/var/log/podvm-build.log"
mkdir -p /var/log

echo "=========================================="
echo "Configuring SSHD service..."
echo "=========================================="

# Log to both console and persistent log file
{
    echo "=========================================="
    echo "PodVM Build Configuration"
    echo "Build Date: $(date)"
    echo "=========================================="
    echo ""
} | tee -a "$BUILD_LOG"

# SSHD_DISABLE_PLACEHOLDER - This line will be replaced by remote-build.sh

# Make log readable
chmod 644 "$BUILD_LOG"

systemctl enable /etc/systemd/system/luks-scratch.service

# Configure SSH service based on SSHD_SERVICE environment variable
# Default is enabled (true), set to 'false' to disable for security
if [ "${SSHD_SERVICE:-true}" = "false" ]; then
    echo "Disabling SSH service for security..."
    systemctl disable sshd.service
    systemctl mask sshd.service
    echo "✓ SSH service disabled and masked"
else
    echo "SSH service remains enabled (default)"
fi

# Configuration to make PCR values to be printed at boot
cat <<EOF > /usr/libexec/gen-issue
#!/usr/bin/env bash

set -euo pipefail

if ! tpm2_pcrread sha256:0 > /dev/null 2>&1; then
   echo "No vTPM detected"
   exit 0
fi

mkdir -p /run/issue.d

rm -f /etc/issue.net
rm -f /etc/issue
{
  echo "Detected vTPM PCR values:"
  /usr/bin/tpm2_pcrread sha256:all
  echo
} > /run/issue.d/30-pcrs.issue
EOF

# this will allow /run/issue and /run/issue.d to take precedence
mv /etc/issue.d /usr/lib/issue.d || true
rm -f /etc/issue.net
rm -f /etc/issue

chmod +x /usr/libexec/gen-issue
cat  <<EOF > /etc/systemd/system/gen-issue.service
[Unit]
Description=Generate issue to print to serial console at startup
Before=serial-getty@ttyS0.service
After=process-user-data.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/gen-issue

[Install]
WantedBy=multi-user.target
EOF
ln -s ../gen-issue.service /etc/systemd/system/multi-user.target.wants/gen-issue.service

# configuration to extend PCR8 with the initdata.digest
mkdir -p /etc/systemd/system/process-user-data.service.d/
cat  <<EOF > /etc/systemd/system/process-user-data.service.d/10-override.conf
[Service]
# mount config disk if available
ExecStartPre=-/bin/mount -t iso9660 -o ro /dev/disk/by-label/cidata /media/cidata
# The digest is a string in hex representation, we truncate it to a 32 bytes hex string
ExecStartPost=-/bin/bash -c 'tpm2_pcrextend 8:sha256=\$(head -c64 /run/peerpod/initdata.digest)'
EOF

# Install Uptycs EDR agent
echo "=========================================="
echo "Installing Uptycs EDR agent..."
echo "=========================================="

# Debug: List files in /scripts/coco/podvm/
echo "DEBUG: Files in /scripts/coco/podvm/:"
ls -la /scripts/coco/podvm/ || echo "ERROR: Directory not found"
echo ""

# Check for install script
if [ -f /scripts/coco/podvm/install-uptycs.sh ]; then
    echo "✓ Found install-uptycs.sh, running installation..."
    echo ""
    
    # Run the installation script with verbose output
    bash -x /scripts/coco/podvm/install-uptycs.sh
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "=========================================="
        echo "✓ Uptycs EDR agent installed successfully"
        echo "=========================================="
        
        # Verify installation
        echo "Verification:"
        echo "  Binary: $(ls -lh /opt/uptycs/bin/osqueryd 2>&1)"
        echo "  Service: $(ls -lh /etc/systemd/system/uptycs-osquery.service 2>&1)"
        echo "  Enabled: $(systemctl is-enabled uptycs-osquery.service 2>&1)"
    else
        echo ""
        echo "=========================================="
        echo "⚠ Uptycs EDR installation FAILED"
        echo "=========================================="
    fi
else
    echo "=========================================="
    echo "⚠ install-uptycs.sh NOT FOUND, skipping"
    echo "=========================================="
fi
echo ""

# ---------------------------------------------------------------------------
# DEBUG LOGGING — placed at END of podvm_maker.sh so it runs AFTER all
# tar extractions (podvm-binaries.tar.gz contains kata-agent.service.d/10-override.conf
# which would overwrite debug overrides written earlier by script-disk-mods.sh).
# Set DEBUG_BUILD=1 to enable verbose console output from all CoCo services.
# ---------------------------------------------------------------------------
if [ "${DEBUG_BUILD:-0}" = "1" ]; then
  echo "=== DEBUG_BUILD=1: overwriting agent-config.toml and service drop-ins for debug ==="

  # agent-config.toml: debug log level, no signature verification
  cat > /etc/agent-config.toml << 'EOF'
server_addr = "unix:///run/kata-containers/agent.sock"
guest_components_procs = "none"
image_registry_auth = "file:///run/peerpod/auth.json"
log_level = "debug"
EOF
  echo "✓ Wrote debug agent-config.toml"

  # kata-agent: RUST_LOG=debug, console output, restart on failure
  mkdir -p /etc/systemd/system/kata-agent.service.d
  cat > /etc/systemd/system/kata-agent.service.d/10-override.conf << 'EOF'
[Service]
ExecStartPre=sh -c '[ -b /dev/mapper/scratch ] && mount /dev/mapper/scratch /kata-containers'
Restart=on-failure
RestartSec=5s
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
ExecStopPost=/bin/bash -c 'echo "=== kata-agent stopped: SERVICE_RESULT=%s EXIT_CODE=%s EXIT_STATUS=%s ===" > /dev/console; journalctl -b -u kata-agent -n 30 --no-pager > /dev/console 2>&1'
EOF
  echo "✓ Wrote kata-agent debug override"

  # agent-protocol-forwarder: RUST_LOG=debug, console output
  mkdir -p /etc/systemd/system/agent-protocol-forwarder.service.d
  cat > /etc/systemd/system/agent-protocol-forwarder.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF
  echo "✓ Wrote APF debug override"

  # attestation-agent: RUST_LOG=debug, console output
  mkdir -p /etc/systemd/system/attestation-agent.service.d
  cat > /etc/systemd/system/attestation-agent.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF
  echo "✓ Wrote attestation-agent debug override"

  # confidential-data-hub: RUST_LOG=debug, console output
  mkdir -p /etc/systemd/system/confidential-data-hub.service.d
  cat > /etc/systemd/system/confidential-data-hub.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF
  echo "✓ Wrote CDH debug override"

  echo "=== DEBUG_BUILD setup complete (placed at end of podvm_maker.sh) ==="
fi

# ---------------------------------------------------------------------------
# VERSION MANIFEST — written last, after all tar extractions.
# Baked into the QCOW2 before dm-verity is computed, so it is part of the
# signed filesystem. Readable at runtime: cat /etc/podvm-version.json
# Also written to /tmp/podvm-version.json for the build host to copy out.
# ---------------------------------------------------------------------------
echo "=== Writing version manifest ==="

KERNEL_VERSION=$(ls /usr/lib/modules/ 2>/dev/null | head -1 || echo "unknown")
UKI_FILE=$(ls /boot/efi/EFI/Linux/*.efi 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "unknown")
RHEL_VERSION=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}" || echo "unknown")
CDH_MTIME=$(stat -c %Y /usr/local/bin/confidential-data-hub 2>/dev/null || echo "0")
AA_MTIME=$(stat -c %Y /usr/local/bin/attestation-agent 2>/dev/null || echo "0")
KA_MTIME=$(stat -c %Y /usr/local/bin/kata-agent 2>/dev/null || echo "0")
# Convert epoch to ISO date string (busybox date -d not available; use printf trick)
epoch_to_date() { date -u -d "@$1" '+%Y-%m-%d' 2>/dev/null || echo "unknown"; }
CDH_DATE=$(epoch_to_date "$CDH_MTIME")
AA_DATE=$(epoch_to_date "$AA_MTIME")
KA_DATE=$(epoch_to_date "$KA_MTIME")
BUILD_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# PODVM_BINARY and PODVM_BINARY_DIGEST are injected by the container env (from example_run.sh).
# If not set, record "unknown" — the build script asserts these separately.
PAYLOAD_IMAGE="${PODVM_BINARY:-unknown}"
PAYLOAD_DIGEST="${PODVM_BINARY_DIGEST:-unknown}"

cat > /etc/podvm-version.json << MANIFEST
{
  "build_date": "${BUILD_TS}",
  "rhel_version": "${RHEL_VERSION}",
  "kernel_version": "${KERNEL_VERSION}",
  "uki_filename": "${UKI_FILE}",
  "payload_image": "${PAYLOAD_IMAGE}",
  "payload_digest": "${PAYLOAD_DIGEST}",
  "cdh_binary_date": "${CDH_DATE}",
  "aa_binary_date": "${AA_DATE}",
  "kata_agent_binary_date": "${KA_DATE}"
}
MANIFEST

echo "✓ Version manifest written to /etc/podvm-version.json:"
cat /etc/podvm-version.json
