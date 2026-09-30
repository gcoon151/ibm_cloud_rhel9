# Kickstart for creating a RHEL 10 peer pod base QCOW2  —  Layer 1 of 3
#
# Upstream reference: coco-podvm-scripts/helpers/rhel10-dm-root.ks
# Deviations from upstream and rationale: rhel10-experimental/UPSTREAM_DEVIATIONS.md
#   Key deviations: %pre partition pre-creation (#3), no WALinuxAgent (#4), no kdump (#5)
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
ignoredisk --only-use=sda
clearpart --none --initlabel
part /boot/efi --fstype="efi" --ondisk=sda --size=512 --fsoptions="defaults,uid=0,gid=0,umask=077,shortname=winnt"
part /         --fstype="ext4" --ondisk=sda --grow --maxsize=0

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
sfdisk --part-type /dev/sda 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
sfdisk --part-type /dev/sda 1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B

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
