#! /bin/bash

dnf config-manager --add-repo=https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/ && dnf install -y --nogpgcheck e2fsprogs && dnf clean all && dnf config-manager --set-disabled "*centos*"

tar -xzvf /tmp/podvm-binaries.tar.gz -C /
tar -xzvf /tmp/pause-bundle.tar.gz -C /

# Create policy.json for signature verification
# This is required by agent-config.toml's image_policy_file setting
echo "Creating /etc/containers/policy.json..."
mkdir -p /etc/containers
cat > /etc/containers/policy.json << 'EOF'
{
    "default": [
        {
            "type": "insecureAcceptAnything"
        }
    ],
    "transports": {
        "docker": {
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        },
        "docker-daemon": {
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        },
        "containers-storage": {
            "": [
                {
                    "type": "insecureAcceptAnything"
                }
            ]
        }
    }
}
EOF
chmod 644 /etc/containers/policy.json
echo "✓ policy.json created"
echo ""

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
