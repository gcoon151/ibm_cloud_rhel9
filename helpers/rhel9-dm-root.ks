# Kickstart for creating a RHEL9 Azure CVM

# Use text install
text

# Do not run the Setup Agent on first boot
firstboot --disable

# Keyboard layouts
keyboard --vckeymap=us --xlayouts='us'

# System language
lang en_US.UTF-8

# Network information
network --bootproto=dhcp --hostname=localhost.localdomain
firewall --disabled

# Use CDROM
cdrom

# Root password. It will be reset by WALinuxAgent
rootpw redhat123

# Enable SELinux
selinux --enforcing

# System services
services --enabled="sshd,NetworkManager,nm-cloud-setup.service,nm-cloud-setup.timer,cloud-init,cloud-init-local,cloud-config,cloud-final,waagent"

# System timezone
timezone Etc/UTC --utc

# Don't configure X
skipx

# Power down the machine after install
# poweroff
reboot

%pre --erroronfail
sfdisk --wipe always -X gpt /dev/sda << EOF
2048,1032192,C12A7328-F81F-11D2-BA4B-00A0C93EC93B
,5242880,4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
EOF
%end

part /boot/efi --onpart=sda1 --fstype efi
part / --onpart=sda2 --fstype ext4

%packages
@^minimal-environment
openssh-server
kernel
redhat-release

-linux-firmware*
-iwl*

WALinuxAgent
cloud-init
cloud-utils-growpart

NetworkManager-cloud-setup

tpm2-tools
efibootmgr
cryptsetup

# UKI
-dracut-config-rescue
-kernel-core
-kernel-modules
-kernel
kernel-uki-virt
kernel-uki-virt-addons
uki-direct

# versionlock plugin
python3-dnf-plugin-versionlock

afterburn
e2fsprogs

%end

%post --erroronfail
# Parse ORG_ID and ACTIVATION_KEY from kernel command line
ORG_ID=$(cat /proc/cmdline | tr ' ' '\n' | grep '^ORG_ID=' | cut -d= -f2)
ACTIVATION_KEY=$(cat /proc/cmdline | tr ' ' '\n' | grep '^ACTIVATION_KEY=' | cut -d= -f2)

if [ -z "$ORG_ID" ] || [ -z "$ACTIVATION_KEY" ]; then
    echo "ERROR: ORG_ID and ACTIVATION_KEY not found in kernel command line"
    echo "Kernel cmdline: $(cat /proc/cmdline)"
    exit 1
fi

# Register with Red Hat subscription manager
subscription-manager register --org="$ORG_ID" --activationkey="$ACTIVATION_KEY" || echo "Warning: subscription-manager registration failed"

# Update only kernel packages to get CVE-2026-31431 fix
# NOTE: Keeping both old and new kernels - new kernel breaks agent-protocol-forwarder
dnf update -y kernel-uki-virt kernel-uki-virt-addons || echo "Warning: kernel update failed"

# Set NEW kernel as default boot to test CVE fix and identify boot issues
# Find the new kernel UKI file (most recent)
NEW_KERNEL=$(ls -t /boot/efi/EFI/Linux/*.efi | head -1)
if [ -n "$NEW_KERNEL" ]; then
    echo "Setting default boot to NEW kernel: $(basename $NEW_KERNEL)"
    # systemd-boot uses /boot/loader/entries/ for boot entries
    # Set the new kernel as default by updating loader.conf
    echo "default $(basename $NEW_KERNEL .efi)" > /boot/loader/loader.conf
    echo "timeout 3" >> /boot/loader/loader.conf
else
    echo "Warning: Could not find new kernel to set as default"
fi

# Clean up subscription data - remove all traces of credentials
subscription-manager unregister || echo "Warning: unregister failed"
subscription-manager clean || echo "Warning: clean failed"
rm -f /etc/pki/consumer/*.pem
rm -f /etc/pki/entitlement/*.pem
rm -rf /var/lib/rhsm/*
rm -f /var/log/rhsm/*

# installer may change partition GUIDs. Linux root (x86-64):
sfdisk --part-type /dev/sda 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

# speed up UKI install
touch /etc/kernel/install.d/20-grub.install
touch /etc/kernel/install.d/50-dracut.install

# set up fallback boot to UKI
printf "shimx64.efi,redhat,\\\EFI\\\Linux\\\\"`cat /etc/machine-id`"-"`rpm -q --queryformat %{VERSION}-%{RELEASE} kernel-uki-virt`".x86_64.efi ,UKI bootentry\n" | iconv -f ASCII -t UCS-2 > /boot/efi/EFI/redhat/BOOTX64.CSV

# remove 'standard' grub
rpm -e grub2-efi-x64 grub2-common grub2-tools grub2-tools-minimal grubby os-prober

# lock shim to the installed version
yum versionlock add shim-x64

# Deprovision and prepare for Azure
/usr/sbin/waagent -force -deprovision

# Fstrim root
fstrim -v / ||:

%end
