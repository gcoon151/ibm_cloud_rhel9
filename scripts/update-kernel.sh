#!/bin/bash
# Update kernel in the base image to get CVE-2026-31431 fix
# This runs INSIDE the container via virt-customize before other modifications

set -e

IMAGE="$1"
if [ -z "$IMAGE" ]; then
    echo "ERROR: No image specified"
    echo "Usage: $0 <image-path>"
    exit 1
fi

echo "=========================================="
echo "Updating kernel in image: $IMAGE"
echo "=========================================="
echo ""

# Get subscription credentials from environment
ORG_ID="${ORG_ID:-}"
ACTIVATION_KEY="${ACTIVATION_KEY:-}"

if [ -z "$ORG_ID" ] || [ -z "$ACTIVATION_KEY" ]; then
    echo "ERROR: ORG_ID and ACTIVATION_KEY environment variables must be set"
    exit 1
fi

echo "[1/5] Registering with Red Hat subscription manager..."
virt-customize -a "$IMAGE" \
    --run-command "subscription-manager register --org='$ORG_ID' --activationkey='$ACTIVATION_KEY' || echo 'Warning: registration failed'"

echo ""
echo "[2/5] Listing kernels BEFORE update..."
virt-customize -a "$IMAGE" \
    --run-command "
echo '=== Kernels BEFORE update ==='
rpm -qa | grep kernel-uki-virt | sort
echo ''
ls -lh /boot/efi/EFI/Linux/*.efi 2>/dev/null || echo 'No UKI files found'
"

echo ""
echo "[3/5] Updating kernel packages..."
virt-customize -a "$IMAGE" \
    --run-command "
set -x
echo '=== Starting kernel update ==='
dnf update -y kernel-uki-virt kernel-uki-virt-addons
echo '=== Kernel update complete ==='
set +x
"

echo ""
echo "[4/5] Listing kernels AFTER update..."
virt-customize -a "$IMAGE" \
    --run-command "
echo '=== Kernels AFTER update ==='
rpm -qa | grep kernel-uki-virt | sort
echo ''
echo '=== UKI files ==='
ls -lht /boot/efi/EFI/Linux/*.efi
"

echo ""
echo "[5/5] Removing OLD kernel and setting NEW as default..."
virt-customize -a "$IMAGE" \
    --run-command "
set -x
echo '=== Identifying kernels ==='
OLD_KERNELS=\$(rpm -q kernel-uki-virt | head -n -1)
echo \"OLD kernels to remove: \$OLD_KERNELS\"

if [ -n \"\$OLD_KERNELS\" ]; then
    echo '=== Removing OLD kernel packages ==='
    for pkg in \$OLD_KERNELS; do
        OLD_VERSION=\$(echo \$pkg | sed 's/kernel-uki-virt-//')
        echo \"Removing kernel version: \$OLD_VERSION\"
        dnf remove -y kernel-uki-virt-\$OLD_VERSION kernel-uki-virt-addons-\$OLD_VERSION kernel-modules-core-\$OLD_VERSION || echo 'Warning: Some packages not found'
    done
else
    echo 'No old kernels to remove'
fi

echo '=== Setting NEW kernel as default ==='
NEW_KERNEL=\$(ls -t /boot/efi/EFI/Linux/*.efi | head -1)
if [ -n \"\$NEW_KERNEL\" ]; then
    echo \"Setting default boot to: \$(basename \$NEW_KERNEL)\"
    echo \"default \$(basename \$NEW_KERNEL .efi)\" > /boot/loader/loader.conf
    echo \"timeout 3\" >> /boot/loader/loader.conf
    echo 'Boot configuration updated'
else
    echo 'ERROR: Could not find new kernel'
    exit 1
fi
set +x
"

echo ""
echo "[6/7] Verifying final kernel configuration..."
virt-customize -a "$IMAGE" \
    --run-command "
echo '=== FINAL kernel state ==='
rpm -qa | grep kernel-uki-virt | sort
echo ''
echo '=== FINAL UKI files ==='
ls -lh /boot/efi/EFI/Linux/*.efi
echo ''
echo '=== Boot configuration ==='
cat /boot/loader/loader.conf
"

echo ""
echo "[7/7] Cleaning up subscription data..."
virt-customize -a "$IMAGE" \
    --run-command "subscription-manager unregister || echo 'Warning: unregister failed'" \
    --run-command "subscription-manager clean || echo 'Warning: clean failed'" \
    --run-command "rm -f /etc/pki/consumer/*.pem" \
    --run-command "rm -f /etc/pki/entitlement/*.pem" \
    --run-command "rm -rf /var/lib/rhsm/*" \
    --run-command "rm -f /var/log/rhsm/*"

echo ""
echo "=========================================="
echo "Kernel update complete!"
echo "NEW kernel installed, OLD kernel removed"
echo "=========================================="

# Made with Bob
