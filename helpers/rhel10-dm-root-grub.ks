# Kickstart for creating a RHEL 10 peer pod base QCOW2 (GRUB-based) — Layer 1 of 3
#
# Reference: rhel10-experimental/UKI_SECUREBOOT_COEXISTENCE_PLAN.md
#
# Produces a Red Hat-signed GRUB boot chain, dm-verity-ready base image.
# Partition layout:
#   sda1=EFI (EFI System type C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
#   sda2=/boot (XBOOTLDR type BC13C2FF-59E6-4262-A352-B275FD6F7172)
#   sda3=root (Linux root x86-64 type 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709)

cmdline
firstboot --disable
keyboard --vckeymap=us --xlayouts='us'
lang en_US.UTF-8
network --bootproto=dhcp --hostname=localhost.localdomain
firewall --disabled

repo --name="AppStream" --baseurl=file:///run/install/sources/mount-0000-cdrom/AppStream
cdrom
rootpw --lock

selinux --enforcing
services --enabled="sshd,NetworkManager,nm-cloud-setup.service,nm-cloud-setup.timer,cloud-init,cloud-init-local,cloud-config,cloud-final"
timezone Etc/UTC --utc
skipx
poweroff

ignoredisk --only-use=sda
clearpart --none --initlabel
part /boot/efi --fstype="efi"  --ondisk=sda --size=256  --fsoptions="defaults,uid=0,gid=0,umask=077,shortname=winnt"
# EFI/boot are sized for one kernel: the image never installs a second one (holds ~9 MB / ~61 MB).
part /boot     --fstype="ext4" --ondisk=sda --size=512 --label=boot
# Root grows to fill the base disk so the build has room for dnf installs. verity.sh
# (shrink_root_to_fit) shrinks it to its contents before computing the verity hash.
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
# CIS package_systemd-journal-remote_installed: install it here, from the same ISO as systemd,
# so the versions match. Installing it later with dnf upgraded systemd and froze boot (Lesson 94).
systemd-journal-remote

# Grub/Dracut boot requirements instead of UKI
kernel-core
kernel-modules
kernel-modules-extra
grub2-efi-x64
shim-x64
grubby
dracut

# versionlock plugin to pin packages
python3-dnf-plugin-versionlock
afterburn
%end

%post --erroronfail
# Fix partition GUIDs.
# 1. EFI System Partition
sfdisk --part-type /dev/sda 1 C12A7328-F81F-11D2-BA4B-00A0C93EC93B

# 2. Give /boot the Discoverable Partitions XBOOTLDR type (BC13C2FF-59E6-4262-A352-B275FD6F7172)
# This is crucial so systemd-repart doesn't mistake it for a linux-generic partition and block scratch creation
sfdisk --part-type /dev/sda 2 BC13C2FF-59E6-4262-A352-B275FD6F7172

# 3. Linux x86-64 root partition (discover partition number dynamically)
ROOTDEV=$(findmnt -no SOURCE /)
PARTNUM=$(cat /sys/class/block/$(basename $ROOTDEV)/partition)
sfdisk --part-type /dev/sda $PARTNUM 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

# RHSM writable paths — all tmpfs
cat >> /etc/fstab << 'EOF'

# RHSM writable paths — all tmpfs (vendor-data disabled, no subscription-manager at boot)
tmpfs /var/lib/rhsm tmpfs defaults,size=32m,mode=0755 0 0
tmpfs /etc/rhsm     tmpfs defaults,size=32m,mode=0755 0 0
tmpfs /var/log/rhsm tmpfs defaults,size=16m,mode=0755 0 0
EOF

# Create the mountpoint directories.
mkdir -p /var/lib/rhsm /etc/rhsm /var/log/rhsm

# GRUB hardening and configuration
grub2-editenv - set menu_auto_hide=1
cat >> /etc/default/grub << 'EOF'
GRUB_TIMEOUT=0
GRUB_DISABLE_RECOVERY=true
GRUB_ENABLE_BLSCFG=true
GRUB_TERMINAL="serial console"
EOF
grub2-mkconfig -o /boot/grub2/grub.cfg

# Initramfs with verity support
echo 'add_dracutmodules+=" systemd-veritysetup "' > /etc/dracut.conf.d/90-verity.conf
dracut -f --regenerate-all

# Remove the rescue BLS entry — we require exactly one BLS entry (plan §4.1)
rm -f /boot/loader/entries/*-rescue.conf
rm -f /boot/vmlinuz-0-rescue-* /boot/initramfs-0-rescue-*.img 2>/dev/null || true

# Lock packages to installed versions to prevent unexpected reference measurement changes
yum versionlock add shim-x64 grub2-efi-x64 grub2-common kernel-core

fstrim -v / || true
%end
