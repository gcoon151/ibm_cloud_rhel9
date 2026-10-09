#!/bin/bash
# =============================================================================
# script-disk-mods.sh — CoCo overlay: package dependencies only  (Layer 3 of 3)
#
# Upstream reference: coco-podvm-scripts/scripts/coco/podvm/script-disk-mods.sh
# Deviations from upstream and rationale: rhel10-experimental/UPSTREAM_DEVIATIONS.md
#   Key deviation: no kernel install, no UKI copy, no BOOTX64.CSV write (#6)
#
# This script runs inside virt-customize as part of the coco-podvm container
# overlay (Step 4 of build-rhel10-overlay.sh).
#
# SCOPE: Install packages that the CoCo binaries require at runtime.
#        Do NOT install, update, or remove kernel packages.
#        Do NOT touch /boot/efi — Layer 1 (kickstart) owns the EFI partition.
#
# The kernel version and UKI in the image are whatever the base QCOW2 contains.
# Kernel updates are a base-image concern (Layer 1/2), not a coco overlay concern.
# =============================================================================
set -ex

# ---------------------------------------------------------------------------
# Create vpcuser — IBM Cloud RHEL 10 default SSH user
#
# IBM Cloud VPC injects the SSH key into the default_user defined in
# /etc/cloud/cloud.cfg. On stock IBM RHEL 10 images that user is 'vpcuser'
# (uid 1000, groups adm+systemd-journal, sudo NOPASSWD:ALL).
# Our kickstart base creates 'cloud-user' instead. We rename it here so
# cloud-init's ssh_authorized_keys injection lands on the right user.
#
# Without this fix: key is injected into 'vpcuser' by VPC initialization,
# but the user doesn't exist in the image → no authorized_keys → no SSH.
# ---------------------------------------------------------------------------

# Rename cloud-user → vpcuser if cloud-user exists; otherwise create fresh
if id cloud-user &>/dev/null; then
    usermod -l vpcuser -d /home/vpcuser -m cloud-user
    groupmod -n vpcuser cloud-user 2>/dev/null || true
else
    useradd -m -u 1000 -G adm,systemd-journal -s /bin/bash \
        -c "VPC Cloud User" vpcuser
fi

# Ensure sudo NOPASSWD:ALL — matches stock IBM RHEL 10 image
echo 'vpcuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/vpcuser
chmod 440 /etc/sudoers.d/vpcuser

# Update cloud.cfg default_user to vpcuser so cloud-init writes the key there
sed -i 's/^\( *name:\) *cloud-user/\1 vpcuser/' /etc/cloud/cloud.cfg
sed -i 's/^\( *gecos:\).*/\1 VPC Cloud User/' /etc/cloud/cloud.cfg

# CoCo runtime dependencies
dnf install -y xmlsec1 xmlsec1-openssl

# ---------------------------------------------------------------------------
# NVIDIA drivers (optional — gated by NVIDIA_DRIVER_VERSION env var)
# Set NVIDIA_DRIVER_VERSION='' to skip (default for non-GPU images).
# ---------------------------------------------------------------------------
if [ -n "${NVIDIA_DRIVER_VERSION:-}" ]; then
  subscription-manager repos --enable=rhel-10-for-x86_64-supplementary-rpms
  subscription-manager repos --enable=rhel-10-for-x86_64-extensions-rpms

  # Kernel version must match the base QCOW2 exactly.
  # Read it from the running guest rather than hardcoding.
  KERNEL_VERSION=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' kernel-uki-virt)
  KERNEL_VERSION="${KERNEL_VERSION%.x86_64}"

  dnf install -y --setopt=install_weak_deps=False \
      nvidia-driver-${NVIDIA_DRIVER_VERSION} \
      nvidia-driver-cuda-${NVIDIA_DRIVER_VERSION} \
      nvidia-driver-libs-${NVIDIA_DRIVER_VERSION} \
      nvidia-persistenced-${NVIDIA_DRIVER_VERSION} \
      kmod-nvidia-open-${NVIDIA_DRIVER_VERSION}-${KERNEL_VERSION%.el*} \
      nvidia-container-toolkit
  dnf clean all

  echo -e "blacklist nouveau\nblacklist nova_core" > /etc/modprobe.d/blacklist_nv_alt.conf
  sed -i 's/^#no-cgroups = false/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml

  cat << 'EOF' > /usr/local/bin/generate-nvidia-cdi.sh
#!/bin/bash

# Check if NVIDIA GPU is present
if ! lspci | grep -i nvidia > /dev/null 2>&1; then
    echo "No NVIDIA GPU detected, skipping NVIDIA setup" | tee /var/log/nvidia-cdi-gen.log
    exit 0
fi

# Load drivers
nvidia-ctk -d system create-device-nodes --control-devices --load-kernel-modules

nvidia-persistenced

# Set confidential compute to ready state (non-fatal if unsupported)
if nvidia-smi conf-compute -srs 1 2>/dev/null; then
    echo "Confidential Compute enabled" | tee -a /var/log/nvidia-cdi-gen.log
else
    echo "Could not set Confidential Compute GPUs to Ready State" | tee -a /var/log/nvidia-cdi-gen.log
fi

# Generate NVIDIA CDI configuration
nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml >> /var/log/nvidia-cdi-gen.log 2>&1 || exit 1
EOF
  chmod 755 /usr/local/bin/generate-nvidia-cdi.sh

  cat <<'EOF' > /etc/systemd/system/nvidia-cdi.service
[Unit]
Description=Generate NVIDIA CDI Configuration
Before=kata-agent.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/generate-nvidia-cdi.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/nvidia-cdi.service
  ln -s /etc/systemd/system/nvidia-cdi.service /etc/systemd/system/multi-user.target.wants/nvidia-cdi.service
fi

# ---------------------------------------------------------------------------
# DEBUG LOGGING — gate on DEBUG_BUILD env var so production builds are clean
# Set DEBUG_BUILD=1 to enable verbose console output from all CoCo services.
# ---------------------------------------------------------------------------
if [ "${DEBUG_BUILD:-0}" = "1" ]; then
  echo "=== DEBUG_BUILD=1: enabling verbose console logging for CoCo services ==="

  # agent-config.toml: debug log level, cdh spawned by kata-agent (eliminates boot race)
  cat > /etc/agent-config.toml << 'EOF'
server_addr = "unix:///run/kata-containers/agent.sock"
guest_components_procs = "confidential-data-hub"
image_registry_auth = "file:///run/peerpod/auth.json"
log_level = "debug"
EOF

  # kata-agent: RUST_LOG=debug, console output, restart on failure
  mkdir -p /etc/systemd/system/kata-agent.service.d
  cat > /etc/systemd/system/kata-agent.service.d/10-override.conf << 'EOF'
[Unit]
# Ensures kata-agent never starts until luks-scratch has finished formatting and
# opening /dev/mapper/scratch. format-scratch.sh now calls systemd-repart directly
# (unconditionally), so this ordering works regardless of whether dm-verity is active.
# Requires= means kata-agent fails loudly if luks-scratch fails — correct behaviour;
# running without encrypted scratch would silently land container layers in RAM overlay.
# See UPSTREAM_DEVIATIONS.md deviations O-2, O-4.
After=luks-scratch.service
Requires=luks-scratch.service

[Service]
ExecStartPre=sh -c '[ -b /dev/mapper/scratch ] && mount /dev/mapper/scratch /kata-containers'
Restart=on-failure
RestartSec=5s
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF

  # agent-protocol-forwarder: RUST_LOG=debug, console output
  mkdir -p /etc/systemd/system/agent-protocol-forwarder.service.d
  cat > /etc/systemd/system/agent-protocol-forwarder.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF

  # attestation-agent: RUST_LOG=debug, console output
  mkdir -p /etc/systemd/system/attestation-agent.service.d
  cat > /etc/systemd/system/attestation-agent.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF

  # confidential-data-hub: RUST_LOG=debug, console output
  mkdir -p /etc/systemd/system/confidential-data-hub.service.d
  cat > /etc/systemd/system/confidential-data-hub.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF

  # Log kata-agent exit reason to console via ExecStopPost
  # (safer than a systemctl wrapper which intercepts all systemd internal calls)
  mkdir -p /etc/systemd/system/kata-agent.service.d
  cat >> /etc/systemd/system/kata-agent.service.d/10-override.conf << 'EOF'
ExecStopPost=/bin/bash -c 'echo "=== kata-agent stopped: SERVICE_RESULT=%s EXIT_CODE=%s EXIT_STATUS=%s ===" > /dev/console; journalctl -b -u kata-agent -n 30 --no-pager > /dev/console 2>&1'
EOF

  echo "=== DEBUG_BUILD setup complete ==="
fi
