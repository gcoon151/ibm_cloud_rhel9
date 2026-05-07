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

# Secure Boot signature verification
pesign

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

# ============================================
# COMPREHENSIVE LOGGING AND VALIDATION
# ============================================
LOGFILE="/root/kickstart-kernel-debug.log"
exec > >(tee -a "$LOGFILE") 2>&1

log_step() {
    echo ""
    echo "=========================================="
    echo "STEP: $1"
    echo "Time: $(date)"
    echo "=========================================="
}

log_check() {
    echo "CHECK: $1"
}

log_error() {
    echo "ERROR: $1" >&2
}

log_step "Starting kernel update process"

# Register with Red Hat subscription manager
log_step "Registering with Red Hat subscription manager"
if subscription-manager register --org="$ORG_ID" --activationkey="$ACTIVATION_KEY"; then
    log_check "✓ Registration successful"
else
    log_error "✗ Registration failed (exit code: $?)"
    exit 1
fi

# Configure repositories
log_step "Configuring repositories"
subscription-manager repos --disable="*eus*"
log_check "Disabled EUS repos (exit code: $?)"

subscription-manager release --set=9.7
log_check "Set release to 9.7 (exit code: $?)"

subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms
log_check "Enabled baseos repo (exit code: $?)"

subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms
log_check "Enabled appstream repo (exit code: $?)"

log_check "Active repositories:"
subscription-manager repos --list-enabled | grep "Repo ID" | head -5

# Show kernel state BEFORE update
log_step "Kernel state BEFORE update"
log_check "Installed kernel packages:"
rpm -qa | grep kernel-uki-virt | sort
log_check "UKI files in /boot/efi/EFI/Linux/:"
ls -lh /boot/efi/EFI/Linux/*.efi 2>/dev/null || echo "No .efi files found"
log_check "Count of .efi files: $(ls /boot/efi/EFI/Linux/*.efi 2>/dev/null | wc -l)"

# Update kernel
log_step "Updating kernel to fix CVE-2026-31431"
if dnf update -y kernel-uki-virt kernel-uki-virt-addons; then
    log_check "✓ Kernel update successful"
else
    log_error "✗ Kernel update failed (exit code: $?)"
    exit 1
fi

# Show kernel state AFTER update
log_step "Kernel state AFTER update"
log_check "Installed kernel packages:"
rpm -qa | grep kernel-uki-virt | sort
log_check "UKI files in /boot/efi/EFI/Linux/:"
ls -lh /boot/efi/EFI/Linux/*.efi 2>/dev/null || echo "No .efi files found"
log_check "Count of .efi files: $(ls /boot/efi/EFI/Linux/*.efi 2>/dev/null | wc -l)"

# Remove old kernel versions
log_step "Removing old kernel versions"
OLD_KERNELS=$(rpm -q kernel-uki-virt | head -n -1)
if [ -n "$OLD_KERNELS" ]; then
    log_check "Old kernels to remove: $OLD_KERNELS"
    for pkg in $OLD_KERNELS; do
        OLD_VERSION=$(echo $pkg | sed 's/kernel-uki-virt-//')
        log_check "Attempting to remove kernel version: $OLD_VERSION"
        
        # Remove kernel packages
        if dnf remove -y kernel-uki-virt-$OLD_VERSION kernel-uki-virt-addons-$OLD_VERSION kernel-modules-core-$OLD_VERSION; then
            log_check "✓ DNF remove successful for $OLD_VERSION"
        else
            log_error "✗ DNF remove failed for $OLD_VERSION (exit code: $?)"
        fi
        
        # Force remove .efi files if they still exist
        OLD_EFI_PATTERN="/boot/efi/EFI/Linux/*${OLD_VERSION}*"
        if ls $OLD_EFI_PATTERN 2>/dev/null; then
            log_check "Old .efi files still exist, force removing..."
            rm -fv $OLD_EFI_PATTERN
            log_check "Force removal exit code: $?"
        fi
    done
else
    log_check "No old kernels found to remove"
fi

# Show kernel state AFTER removal
log_step "Kernel state AFTER removal"
log_check "Installed kernel packages:"
rpm -qa | grep kernel-uki-virt | sort
log_check "UKI files in /boot/efi/EFI/Linux/:"
ls -lh /boot/efi/EFI/Linux/*.efi 2>/dev/null || echo "No .efi files found"
EFI_COUNT=$(ls /boot/efi/EFI/Linux/*.efi 2>/dev/null | wc -l)
log_check "Count of .efi files: $EFI_COUNT"

# VALIDATION: Ensure exactly ONE .efi file
if [ "$EFI_COUNT" -ne 1 ]; then
    log_error "VALIDATION FAILED: Expected 1 .efi file, found $EFI_COUNT"
    log_error "This will cause verity.sh to fail during PodVM build!"
    log_error "Listing all .efi files:"
    ls -la /boot/efi/EFI/Linux/
    exit 1
else
    log_check "✓ VALIDATION PASSED: Exactly 1 .efi file found"
fi

# Set new kernel as default boot entry
log_step "Setting default boot entry"
NEW_KERNEL=$(ls -t /boot/efi/EFI/Linux/*.efi | head -1)
if [ -n "$NEW_KERNEL" ]; then
    log_check "Setting default boot to: $(basename $NEW_KERNEL)"
    echo "default $(basename $NEW_KERNEL .efi)" > /boot/loader/loader.conf
    echo "timeout 3" >> /boot/loader/loader.conf
    log_check "✓ Boot loader configured"
    log_check "Boot loader config:"
    cat /boot/loader/loader.conf
else
    log_error "✗ No kernel found to set as default"
    exit 1
fi

log_step "Final kernel state summary"
log_check "Kernel packages:"
rpm -qa | grep kernel-uki-virt | sort
log_check "UKI files:"
ls -lh /boot/efi/EFI/Linux/*.efi
log_check "Boot loader:"
cat /boot/loader/loader.conf

log_step "Kernel update process completed successfully"

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
