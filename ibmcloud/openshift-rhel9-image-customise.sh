#!/bin/bash
# -----------------------------------------------------------------------------
# rhel-dm-customize.sh
#
# Equivalent of rhel-dm.ks %post section, expressed as a virt-customize script.
#
# NOTE: The %pre (partitioning) and %packages sections of the kickstart cannot
# be replicated by virt-customize — they require a fresh install.
# This script assumes:
#   - The qcow2 image already has a minimal RHEL 9 install
#   - /dev/sda2 is the root partition (GPT, type 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709)
#   - /dev/sda1 is the EFI partition
#
# Usage:
#   virt-customize -a <image.qcow2> --run rhel-dm-customize.sh
#
# Or with all options in one command:
#   virt-customize -a <image.qcow2> \
#       --hostname localhost.localdomain \
#       --timezone Etc/UTC \
#       --selinux-relabel \
#       --run rhel-dm-customize.sh
# -----------------------------------------------------------------------------
set -euo pipefail

configure_vpcuser_access() {
    sed -i '/^ - ssh$/d' /etc/cloud/cloud.cfg
    ssh-keygen -A
    echo "${ROOT_PASSWORD}" | passwd --stdin vpcuser
    mkdir -p /home/vpcuser/.ssh
    chmod 700 /home/vpcuser/.ssh
    echo "${SSHKEY}" > /home/vpcuser/.ssh/authorized_keys
    chmod 600 /home/vpcuser/.ssh/authorized_keys
    chown -R vpcuser:vpcuser /home/vpcuser/.ssh
    echo "vpcuser ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vpcuser
    chmod 0440 /etc/sudoers.d/vpcuser
}

configure_vpcuser_access

# ── 1. Set root password ──────────────────────────────────────────────────────
echo "redhat123" | passwd --stdin root

# ── 2. Set hostname ───────────────────────────────────────────────────────────
hostnamectl set-hostname localhost.localdomain

# ── 3. Set timezone ───────────────────────────────────────────────────────────
timedatectl set-timezone Etc/UTC || ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime

# ── 4. Set locale and keyboard ───────────────────────────────────────────────
localectl set-locale LANG=en_US.UTF-8 || echo 'LANG=en_US.UTF-8' > /etc/locale.conf
localectl set-keymap us || echo 'KEYMAP=us' > /etc/vconsole.conf

# ── 5. Disable firewall ───────────────────────────────────────────────────────
systemctl disable --now firewalld || true

# ── 6. Enable SELinux enforcing ───────────────────────────────────────────────
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config

# ── 7. Enable required services ───────────────────────────────────────────────
systemctl enable sshd
systemctl enable NetworkManager
systemctl enable nm-cloud-setup.service || true
systemctl enable nm-cloud-setup.timer   || true
systemctl enable cloud-init
systemctl enable cloud-init-local
systemctl enable cloud-config
systemctl enable cloud-final
systemctl enable waagent || true

# ── 8. Install required packages ─────────────────────────────────────────────
dnf install -y \
    openssh-server \
    WALinuxAgent \
    cloud-init \
    cloud-utils-growpart \
    NetworkManager-cloud-setup \
    tpm2-tools \
    efibootmgr \
    cryptsetup \
    python3-dnf-plugin-versionlock \
    afterburn \
    e2fsprogs \
    kernel-uki-virt \
    kernel-uki-virt-addons \
    uki-direct

# ── 9. Remove packages excluded in kickstart ──────────────────────────────────
dnf remove -y \
    linux-firmware \
    dracut-config-rescue \
    kernel-core \
    kernel-modules \
    kernel \
    grub2-efi-x64 \
    grub2-common \
    grub2-tools \
    grub2-tools-minimal \
    grubby \
    os-prober || true

# Remove iwl* (wireless) firmware
dnf remove -y 'iwl*' || true

# ── 10. Speed up UKI install (disable grub/dracut install hooks) ──────────────
touch /etc/kernel/install.d/20-grub.install
touch /etc/kernel/install.d/50-dracut.install

# ── 11. Set up fallback boot to UKI ──────────────────────────────────────────
MACHINE_ID=$(cat /etc/machine-id)
UKI_VER=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' kernel-uki-virt)
printf "shimx64.efi,redhat,\\\EFI\\\Linux\\\\${MACHINE_ID}-${UKI_VER}.x86_64.efi ,UKI bootentry\n" \
    | iconv -f ASCII -t UCS-2 \
    > /boot/efi/EFI/redhat/BOOTX64.CSV

# ── 12. Lock shim to installed version ───────────────────────────────────────
yum versionlock add shim-x64

# ── 13. Deprovision for Azure ────────────────────────────────────────────────
/usr/sbin/waagent -force -deprovision

# ── 14. Fstrim root ───────────────────────────────────────────────────────────
fstrim -v / || true

echo "✔  rhel-dm-customize.sh completed successfully."
