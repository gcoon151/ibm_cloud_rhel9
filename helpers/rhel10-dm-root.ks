# Kickstart for creating a RHEL 10 peer pod base QCOW2  —  Layer 1 of 3
#
# Upstream reference: coco-podvm-scripts/helpers/rhel10-dm-root.ks
# Deviations from upstream and rationale: rhel10-experimental/UPSTREAM_DEVIATIONS.md
#   Key deviations: %pre partition pre-creation (#3), no WALinuxAgent (#4), no kdump (#5),
#                   rhsm-rw partition (#14)
#
# Produces a UKI-boot, dm-verity-ready base image.
# The EFI partition is fully set up by this kickstart — kernel-install fires
# during the OS install and places the UKI in /boot/efi/EFI/Linux/ correctly.
# The coco overlay container (Layer 3) must not reinstall kernels or touch EFI.
#
# Usage:
#   virt-install --virt-type kvm --os-variant rhel10.0 --arch x86_64 --boot uefi \
#     --name rhel10-ks-base --memory 8192 \
#     --location rhel-10.2-x86_64-dvd.iso \
#     --disk bus=scsi,size=7 \
#     --initrd-inject=helpers/rhel10-dm-root.ks --nographics \
#     --extra-args "console=ttyS0 inst.ks=file:/rhel10-dm-root.ks" --transient
#
# The target kernel version is pinned so the base image is reproducible.
# To update: change KERNEL_VERSION here and rebuild the base QCOW2.
# The coco overlay layer (script-disk-mods.sh) must not change the kernel.

# Fully unattended install — no interactive prompts.
# 'cmdline' mode: Anaconda runs non-interactively and aborts if anything
# requires user input, rather than sitting at a prompt indefinitely.
cmdline

# Do not run the Setup Agent on first boot
firstboot --disable

# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us'

# System language
lang en_US.UTF-8

# Network — dhcp. Anaconda 40 on RHEL 10.2 does not accept bootproto=none.
# DHCP may time out (60-90s) but Anaconda proceeds without it.
# peer pod VMs get their network config from cloud-init/afterburn at runtime.
network --bootproto=dhcp --hostname=localhost.localdomain
firewall --disabled

# AppStream repo from CDROM — required so Anaconda can resolve packages
# like kernel-uki-virt that are in AppStream, not just BaseOS.
repo --name="AppStream" --baseurl=file:///run/install/sources/mount-0000-cdrom/AppStream

# Use CDROM
cdrom

# Root password (reset by cloud-init / afterburn on first boot)
rootpw redhat123

# Enable SELinux
selinux --enforcing

# System services
services --enabled="sshd,NetworkManager,nm-cloud-setup.service,nm-cloud-setup.timer,cloud-init,cloud-init-local,cloud-config,cloud-final"

# System timezone
timezone Etc/UTC --utc

# Don't configure X
skipx

# Power down after install so the QCOW2 is not left in a running state
poweroff

# Partition layout — Anaconda auto-create, then fix GUIDs in %post.
# NOTE: %pre sfdisk + --onpart was tried in run B-1 and caused Anaconda to
# stall (52KB written in 30 min). Reverted to upstream pattern for B-2.
# See rhel10-experimental/BUILD_BASELINE.md Run B-1 for details.
#
# Partition 3 — rhsm-rw (128 MiB, plain ext4, deviation #14):
#   IBM Cloud injects vendor-data that runs cloud-init's rh_subscription module,
#   which calls subscription-manager. subscription-manager writes runtime state
#   to /var/lib/rhsm/ (entitlements, certs, facts, cache — ~2-5 MB in practice).
#   The root partition is dm-verity protected and read-only after boot, so these
#   writes fail → rh_subscription reports failure → power_state_change powers off
#   the VM at ~35s, before kata-agent completes its handshake.
#
#   Fix: a small plain ext4 partition labelled "rhsm-rw", mounted at /var/lib/rhsm
#   via fstab (available before cloud-init's first stage). /etc/rhsm and
#   /var/log/rhsm are covered by tmpfs entries in fstab (config is small and
#   re-created each boot from IBM Cloud vendor-data; logs are ephemeral).
#
#   systemd-repart (luks-scratch) runs later and claims the remaining free space
#   after this partition — the label "rhsm-rw" prevents repart from touching it.
#
#   128 MiB is generous; registered RHEL systems typically use <10 MiB here.
#   This partition is NOT covered by dm-verity (verity covers the root partition
#   only). It intentionally has no verity protection because it must be writable.
ignoredisk --only-use=sda
clearpart --none --initlabel
part /boot/efi     --fstype="efi"  --ondisk=sda --size=512 --fsoptions="defaults,uid=0,gid=0,umask=077,shortname=winnt"
part /             --fstype="ext4" --ondisk=sda --grow --maxsize=0
part /var/lib/rhsm --fstype="ext4" --ondisk=sda --size=128 --label=rhsm-rw
# NOTE: --grow must come before the fixed-size partition so Anaconda assigns
# sda1=EFI, sda2=root(grow), sda3=rhsm-rw(128MB) in that order.
# The --label here sets the ext4 filesystem label (e2label), not the GPT
# partition name. The %post sfdisk call below fixes sda2's GUID; sda3 keeps
# the default linux-generic GUID which is correct for a data partition.

%packages
@^minimal-environment
openssh-server
redhat-release

-linux-firmware*
-iwl*
-*gpu-firmware*

cloud-init
cloud-utils-growpart
NetworkManager-cloud-setup

tpm2-tools
efibootmgr
cryptsetup
e2fsprogs

# UKI boot — kernel-install fires during OS install and places the UKI
# in /boot/efi/EFI/Linux/ automatically. No post-install UKI copy needed.
# Exclude standard kernel and dracut-rescue — replaced by kernel-uki-virt.
# Do NOT exclude kernel-modules: kernel-modules-extra depends on it and
# Anaconda will reject the package set if it is excluded.
-dracut-config-rescue
-kernel-core
-kernel
kernel-modules
kernel-uki-virt
uki-direct

# versionlock plugin — used to pin shim after install
python3-dnf-plugin-versionlock

# Cloud metadata / peer pod requirements
afterburn
kernel-modules-extra

%end

%post --erroronfail
# Fix partition GUIDs — Anaconda may reset them during install.
# Linux x86-64 root: 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
# EFI System:        C12A7328-F81F-11D2-BA4B-00A0C93EC93B
# rhsm-rw (sda3, linux-generic): 0FC63DAF-8483-4772-8E79-3D69D8477DE4 — no change needed
sfdisk --part-type /dev/sda 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
sfdisk --part-type /dev/sda 1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B
# Set GPT partition name on sda3 so rebuild-base-rhel10.sh can identify it.
# (--label in kickstart sets ext4 filesystem label, not GPT name.)
sfdisk --part-label /dev/sda 3 rhsm-rw

# Add fstab entries for RHSM writable paths (deviation #14).
# /var/lib/rhsm is on the rhsm-rw partition (already in fstab via Anaconda).
# /etc/rhsm and /var/log/rhsm are tmpfs — small, ephemeral, re-created each boot.
# Both are available before cloud-init's network stage (systemd mounts them from
# fstab during early boot, before any cloud-init unit starts).
cat >> /etc/fstab << 'EOF'

# RHSM writable paths — deviation #14 (see rhel10-experimental/UPSTREAM_DEVIATIONS.md)
# /var/lib/rhsm is already mounted via the rhsm-rw partition entry above.
# /etc/rhsm: tmpfs so subscription-manager can write config on first boot.
tmpfs /etc/rhsm     tmpfs defaults,size=32m,mode=0755 0 0
# /var/log/rhsm: tmpfs for logs — ephemeral, not needed across reboots.
tmpfs /var/log/rhsm tmpfs defaults,size=16m,mode=0755 0 0
EOF

# Create the mountpoint directories (they may not exist in the minimal install).
mkdir -p /etc/rhsm /var/log/rhsm

# Speed up kernel-install by disabling grub and dracut hooks (UKI replaces them).
touch /etc/kernel/install.d/20-grub.install
touch /etc/kernel/install.d/50-dracut.install

# Write shim fallback CSV so firmware can find the UKI.
# kernel-install placed the UKI at /boot/efi/EFI/Linux/<machine-id>-<ver>.x86_64.efi
printf "shimx64.efi,redhat,\\\EFI\\\Linux\\\\$(cat /etc/machine-id)-$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' kernel-uki-virt).x86_64.efi ,UKI bootentry\n" \
    | iconv -f ASCII -t UCS-2 > /boot/efi/EFI/redhat/BOOTX64.CSV

# Remove standard grub — UKI boots directly via shim.
rpm -e grub2-efi-x64 grub2-common grub2-tools grub2-tools-minimal grubby os-prober 2>/dev/null || true

# Lock shim to the installed version so updates don't accidentally break Secure Boot.
yum versionlock add shim-x64

# Fstrim
fstrim -v / || true

%end
