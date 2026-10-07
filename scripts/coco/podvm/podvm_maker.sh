#! /bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# podvm_maker.sh — IBM-specific guest configuration for RHEL 10 peer pod images
#
# Runs inside the guest via virt-customize. Every step either succeeds
# completely or fails loudly with a message naming exactly what broke.
# No step silently continues past a failure.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Step 1: Verify e2fsprogs (needed for luks-scratch mkfs.ext4 at runtime)
# ---------------------------------------------------------------------------
# e2fsprogs is pre-installed in the coco-podvm container via the Dockerfile.
# Previously this step added mirror.stream.centos.org as a repo to install it,
# but that mirror is flaky and e2fsprogs is already present — no install needed.
echo "=== [1/6] Verifying e2fsprogs ==="
if ! rpm -q e2fsprogs &>/dev/null; then
    echo "ERROR: e2fsprogs not found — install it in the coco-podvm Dockerfile" >&2
    exit 1
fi
echo "✓ e2fsprogs already installed: $(rpm -q e2fsprogs)"

# ---------------------------------------------------------------------------
# Step 2: Extract payload tarballs and assert binaries landed correctly
# ---------------------------------------------------------------------------
echo ""
echo "=== [2/6] Extracting payload tarballs ==="
echo "  podvm-binaries.tar.gz: $(ls -lh /tmp/podvm-binaries.tar.gz 2>/dev/null || echo 'NOT FOUND')"
echo "  pause-bundle.tar.gz:   $(ls -lh /tmp/pause-bundle.tar.gz   2>/dev/null || echo 'NOT FOUND')"
echo "  luks-config.tar.gz:    $(ls -lh /tmp/luks-config.tar.gz    2>/dev/null || echo 'NOT FOUND')"

for tarball in /tmp/podvm-binaries.tar.gz /tmp/pause-bundle.tar.gz; do
    if [[ ! -f "${tarball}" ]]; then
        echo "ERROR: ${tarball} not found — payload injection failed upstream" >&2
        exit 1
    fi
done

echo "  Extracting podvm-binaries.tar.gz..."
if ! tar -xzvf /tmp/podvm-binaries.tar.gz -C /; then
    echo "ERROR: failed to extract /tmp/podvm-binaries.tar.gz" >&2
    exit 1
fi
echo "✓ podvm-binaries extracted"

echo "  Extracting pause-bundle.tar.gz..."
if ! tar -xzvf /tmp/pause-bundle.tar.gz -C /; then
    echo "ERROR: failed to extract /tmp/pause-bundle.tar.gz" >&2
    exit 1
fi
echo "✓ pause-bundle extracted"

# Assert critical binaries and config landed
echo "  Asserting key binaries present in /usr/local/bin/ ..."
for binary in kata-agent agent-protocol-forwarder kata-agent-clean; do
    if [[ ! -f /usr/local/bin/${binary} ]]; then
        echo "ERROR: /usr/local/bin/${binary} missing after tar extraction" >&2
        echo "  Tarball contents (usr/local/bin):" >&2
        tar -tzf /tmp/podvm-binaries.tar.gz 2>/dev/null | grep "usr/local/bin/" | head -20 >&2
        exit 1
    fi
    echo "  ✓ /usr/local/bin/${binary} ($(ls -lh /usr/local/bin/${binary} | awk '{print $5}'))"
done

if [[ ! -f /etc/agent-config.toml ]]; then
    echo "ERROR: /etc/agent-config.toml missing after tar extraction" >&2
    exit 1
fi
echo "  ✓ /etc/agent-config.toml present"

# Patch agent-config.toml: add image_registry_auth if missing (upstream payload omits it).
# Note: guest_components_procs = "none" is correct — AA and CDH are launched by their
# own systemd path units (attestation-agent.path, confidential-data-hub.path), not as
# sub-processes of kata-agent.
echo "Patching agent-config.toml..."
if ! grep -q "image_registry_auth" /etc/agent-config.toml; then
    if ! echo 'image_registry_auth = "file:///run/peerpod/auth.json"' >> /etc/agent-config.toml; then
        echo "ERROR: failed to patch /etc/agent-config.toml — is it read-only?" >&2
        exit 1
    fi
    echo "✓ Added image_registry_auth to agent-config.toml"
else
    echo "✓ image_registry_auth already present in agent-config.toml"
fi

# Enable confidential-data-hub.path — the OSC payload installs the unit file but does
# NOT create the symlink in multi-user.target.wants. Without it CDH never starts,
# cdh.sock never appears, and kata-agent.path never fires (CreateContainer timeout).
echo "Enabling confidential-data-hub.path..."
if [[ ! -f /etc/systemd/system/confidential-data-hub.path ]]; then
    echo "ERROR: /etc/systemd/system/confidential-data-hub.path not found" >&2
    echo "       The unit should have been extracted from podvm-binaries.tar.gz" >&2
    exit 1
fi
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/confidential-data-hub.path \
       /etc/systemd/system/multi-user.target.wants/confidential-data-hub.path
if [[ ! -L /etc/systemd/system/multi-user.target.wants/confidential-data-hub.path ]]; then
    echo "ERROR: failed to create confidential-data-hub.path symlink" >&2
    exit 1
fi
echo "✓ confidential-data-hub.path enabled"

# NOTE: enable_signature_verification is intentionally NOT baked into the image.
# When baked in, it causes CreateSandbox to fail with the nosigning initdata
# because kata-agent tries to fetch the image policy from KBS before the container
# starts, and KBS attestation fails in that context. The signing config is
# applied at the cluster level via initdata when signature verification is needed.

# ---------------------------------------------------------------------------
# Step 3: Extract luks-config and assert service file present
# ---------------------------------------------------------------------------
echo ""
echo "=== [3/6] Extracting luks-config.tar.gz ==="
if [[ ! -f /tmp/luks-config.tar.gz ]]; then
    echo "ERROR: /tmp/luks-config.tar.gz not found" >&2
    exit 1
fi
if ! tar -xzvf /tmp/luks-config.tar.gz -C /; then
    echo "ERROR: failed to extract /tmp/luks-config.tar.gz" >&2
    exit 1
fi
if [[ ! -f /etc/systemd/system/luks-scratch.service ]]; then
    echo "ERROR: luks-scratch.service missing after luks-config extraction" >&2
    exit 1
fi
echo "✓ luks-config extracted, luks-scratch.service present"

# ---------------------------------------------------------------------------
# Step 4: SELinux context fixes + firewall
# ---------------------------------------------------------------------------
# apply_selinux_label writes the fcontext rule (semanage) and runs restorecon.
#
# IMPORTANT — why there is no in-guest label verification here:
# Inside virt-customize, restorecon writes the rule to file_contexts.local but
# virt-customize's own SELinux relabelling pass (which runs at the very end,
# after all --run scripts complete) is what actually applies labels to inodes.
# Calling ls -Z immediately after restorecon will show the old label because
# the relabelling hasn't happened yet. Evidence: C-14 builder.log shows
# restorecon -v on kata-agent printed no "Relabeled" line, yet the final image
# had bin_t. In-guest verification would produce a false failure.
#
# Real verification happens on the HOST after the container finishes, in
# build-rhel10-overlay.sh Step 5c, using guestfish getxattr to read the
# security.selinux xattr directly from the QCOW2.
#
# On RHEL 10, /usr/sbin is a symlink to /usr/bin (filesystem unification).
# SELinux equivalency rules reject semanage fcontext on /usr/sbin/ip with:
#   "File spec /usr/sbin/ip conflicts with equivalency rule '/usr/sbin /usr/bin'"
# The canonical path for semanage is /usr/bin/ip; restorecon targets /usr/sbin/ip
# (the on-disk path to relabel). These are intentionally different arguments.

apply_selinux_label() {
    local semanage_path="$1"   # canonical path for semanage fcontext rule
    local restorecon_path="$2" # on-disk path for restorecon (may differ due to /usr/sbin→/usr/bin)
    local expected_type="$3"   # SELinux type to verify, e.g. bin_t

    echo "  Labelling ${restorecon_path} as ${expected_type}..."

    if [[ ! -e "${restorecon_path}" ]]; then
        echo "ERROR: ${restorecon_path} does not exist — cannot set SELinux label" >&2
        return 1
    fi

    if ! semanage fcontext -a -t "${expected_type}" "${semanage_path}"; then
        echo "ERROR: semanage fcontext -a -t ${expected_type} ${semanage_path} failed" >&2
        echo "       Current rules: $(semanage fcontext -l 2>/dev/null | grep "$(basename ${semanage_path})" || echo 'none')" >&2
        return 1
    fi

    # restorecon writes to file_contexts.local so virt-customize's end-of-run
    # relabelling pass picks it up. The label is not visible via ls -Z yet —
    # see comment above. Failure here is still a hard stop.
    if ! restorecon -v "${restorecon_path}"; then
        echo "ERROR: restorecon failed for ${restorecon_path}" >&2
        return 1
    fi

    echo "  ✓ ${restorecon_path}: fcontext rule set, restorecon queued"
}

echo ""
echo "=== [4/6] Fixing SELinux contexts and firewall ==="

# /usr/bin/ip (canonical) → restorecon /usr/sbin/ip (on-disk path on RHEL 10)
# Required for netns@podns.service: SELinux blocks 'ip netns add' without bin_t
apply_selinux_label /usr/bin/ip /usr/sbin/ip bin_t

# kata-agent binaries — /usr/local/bin has no equivalency rules so both paths are the same
apply_selinux_label /usr/local/bin/kata-agent       /usr/local/bin/kata-agent       bin_t
apply_selinux_label /usr/local/bin/kata-agent-clean /usr/local/bin/kata-agent-clean bin_t

# Open port 15150 for agent-protocol-forwarder — required on RHEL 10 where
# firewalld is active by default and blocks the port otherwise.
# (upstream coco-podvm-scripts PR #79 — RHEL 10 networking requirements)
if ! firewall-offline-cmd --zone=public --add-port=15150/tcp; then
    echo "ERROR: firewall-offline-cmd failed — port 15150 will be blocked at runtime" >&2
    exit 1
fi

echo "✓ SELinux fcontext rules set, restorecon queued, port 15150 opened in firewall"

# ---------------------------------------------------------------------------
# Step 5: System configuration (services, systemd units)
# ---------------------------------------------------------------------------
echo ""
echo "=== [5/6] System configuration ==="

if ! systemctl enable /etc/systemd/system/luks-scratch.service; then
    echo "ERROR: failed to enable luks-scratch.service" >&2
    exit 1
fi
echo "✓ luks-scratch.service enabled"

# Configure SSH service based on SSHD_SERVICE environment variable.
# Default is enabled (true); set to 'false' to produce a hardened image.
if [ "${SSHD_SERVICE:-true}" = "false" ]; then
    echo "Disabling SSH service for hardened image..."
    if ! systemctl disable sshd.service; then
        echo "ERROR: failed to disable sshd.service" >&2
        exit 1
    fi
    if ! systemctl mask sshd.service; then
        echo "ERROR: failed to mask sshd.service" >&2
        exit 1
    fi
    echo "✓ SSH service disabled and masked"
else
    echo "✓ SSH service remains enabled (SSHD_SERVICE=${SSHD_SERVICE:-true})"
fi

# gen-issue service: print PCR values to serial console at boot
cat <<'EOF' > /usr/libexec/gen-issue
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

# allow /run/issue and /run/issue.d to take precedence over /etc/issue
mv /etc/issue.d /usr/lib/issue.d 2>/dev/null || true
rm -f /etc/issue.net
rm -f /etc/issue

chmod +x /usr/libexec/gen-issue

cat <<'EOF' > /etc/systemd/system/gen-issue.service
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

# ln -s will fail if symlink already exists; -f handles idempotent re-runs
ln -sf ../gen-issue.service /etc/systemd/system/multi-user.target.wants/gen-issue.service
echo "✓ gen-issue.service installed"

# PCR8 extension with initdata.digest
mkdir -p /etc/systemd/system/process-user-data.service.d/
cat <<'EOF' > /etc/systemd/system/process-user-data.service.d/10-override.conf
[Service]
# mount config disk if available
ExecStartPre=-/bin/mount -t iso9660 -o ro /dev/disk/by-label/cidata /media/cidata
# The digest is a string in hex representation, we truncate it to a 32 bytes hex string
ExecStartPost=-/bin/bash -c 'tpm2_pcrextend 8:sha256=$(head -c64 /run/peerpod/initdata.digest)'
EOF
echo "✓ process-user-data PCR8 override installed"

# ---------------------------------------------------------------------------
# Step 6: Install Uptycs EDR agent
# ---------------------------------------------------------------------------
echo ""
echo "=== [6/6] Installing Uptycs EDR agent ==="
# TODO: Uptycs installation is temporarily disabled while the core image is being
# validated. The staging mechanism (virt-copy-in in build-rhel10-overlay.sh) has not
# been implemented yet. The full hard-fail enforcement below is written and ready —
# uncomment it once staging is in place and the install script is validated on RHEL 10.
#
# UPTYCS_INSTALL=/tmp/uptycs-install/install-uptycs.sh
# if [[ ! -f "${UPTYCS_INSTALL}" ]]; then
#     echo "ERROR: ${UPTYCS_INSTALL} not found in guest filesystem" >&2
#     echo "       build-rhel10-overlay.sh must stage Uptycs scripts via virt-copy-in" >&2
#     echo "       before calling example_run.sh. See UPSTREAM_DEVIATIONS.md." >&2
#     exit 1
# fi
# if ! bash "${UPTYCS_INSTALL}"; then
#     echo "ERROR: Uptycs installation script failed (exit $?)" >&2
#     exit 1
# fi
# for uptycs_check in /opt/uptycs/bin/osqueryd /etc/systemd/system/uptycs-osquery.service; do
#     if [[ ! -e "${uptycs_check}" ]]; then
#         echo "ERROR: Uptycs post-install check failed — ${uptycs_check} not found" >&2
#         exit 1
#     fi
# done
# if ! systemctl is-enabled uptycs-osquery.service &>/dev/null; then
#     echo "ERROR: uptycs-osquery.service is not enabled after installation" >&2
#     exit 1
# fi
# echo "✓ Uptycs EDR agent installed and enabled"
echo "⚠ Uptycs installation skipped (staging not yet implemented — see TODO above)"

# ---------------------------------------------------------------------------
# DEBUG LOGGING — placed at END so it runs after all tar extractions.
# (podvm-binaries.tar.gz contains kata-agent.service.d/10-override.conf which
# would overwrite debug overrides written earlier by script-disk-mods.sh.)
# Set DEBUG_BUILD=1 to enable verbose console output from all CoCo services.
# ---------------------------------------------------------------------------
if [ "${DEBUG_BUILD:-0}" = "1" ]; then
    echo "=== DEBUG_BUILD=1: overwriting agent-config.toml and service drop-ins for debug ==="

    cat > /etc/agent-config.toml << 'EOF'
server_addr = "unix:///run/kata-containers/agent.sock"
guest_components_procs = "none"
image_registry_auth = "file:///run/peerpod/auth.json"
log_level = "debug"
EOF
    echo "✓ Wrote debug agent-config.toml"

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

    mkdir -p /etc/systemd/system/agent-protocol-forwarder.service.d
    cat > /etc/systemd/system/agent-protocol-forwarder.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF
    echo "✓ Wrote APF debug override"

    mkdir -p /etc/systemd/system/attestation-agent.service.d
    cat > /etc/systemd/system/attestation-agent.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF
    echo "✓ Wrote attestation-agent debug override"

    mkdir -p /etc/systemd/system/confidential-data-hub.service.d
    cat > /etc/systemd/system/confidential-data-hub.service.d/10-override.conf << 'EOF'
[Service]
Environment=RUST_LOG=debug
StandardOutput=journal+console
StandardError=journal+console
EOF
    echo "✓ Wrote CDH debug override"

    echo "=== DEBUG_BUILD setup complete ==="
fi

# ---------------------------------------------------------------------------
# VERSION MANIFEST — written last, after all tar extractions.
# Baked into the QCOW2 before dm-verity is computed, so it is part of the
# signed root hash. Readable at runtime: cat /etc/podvm-version.json
# ---------------------------------------------------------------------------
echo "=== Writing version manifest ==="

# Each of these is a hard failure — if any binary is missing here, the image
# is broken regardless of what the earlier extraction steps reported.
for bin in /usr/local/bin/confidential-data-hub /usr/local/bin/attestation-agent /usr/local/bin/kata-agent; do
    if [[ ! -f "${bin}" ]]; then
        echo "ERROR: ${bin} not found when writing version manifest — extraction failed" >&2
        exit 1
    fi
done

UKI_FILE=$(ls /boot/efi/EFI/Linux/*.efi 2>/dev/null | head -1 | xargs -r basename)
if [[ -z "${UKI_FILE}" ]]; then
    echo "ERROR: no UKI (.efi) found in /boot/efi/EFI/Linux/ — kickstart or kernel install failed" >&2
    exit 1
fi

KERNEL_VERSION=$(ls /usr/lib/modules/ 2>/dev/null | head -1)
if [[ -z "${KERNEL_VERSION}" ]]; then
    echo "ERROR: no kernel found in /usr/lib/modules/ — base image is broken" >&2
    exit 1
fi

RHEL_VERSION=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}" || echo "unknown")
CDH_MTIME=$(stat -c %Y /usr/local/bin/confidential-data-hub)
AA_MTIME=$(stat -c %Y  /usr/local/bin/attestation-agent)
KA_MTIME=$(stat -c %Y  /usr/local/bin/kata-agent)

epoch_to_date() { date -u -d "@$1" '+%Y-%m-%d'; }
CDH_DATE=$(epoch_to_date "$CDH_MTIME")
AA_DATE=$(epoch_to_date "$AA_MTIME")
KA_DATE=$(epoch_to_date "$KA_MTIME")
BUILD_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# PODVM_BINARY and PODVM_BINARY_DIGEST are injected by the container env (from example_run.sh).
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
