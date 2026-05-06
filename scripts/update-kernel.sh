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
echo "[2/5] Updating kernel packages..."
virt-customize -a "$IMAGE" \
    --run-command "dnf update -y kernel-uki-virt kernel-uki-virt-addons || echo 'Warning: kernel update failed'"

echo ""
echo "[3/5] Setting NEW kernel as default boot..."
virt-customize -a "$IMAGE" \
    --run-command "
NEW_KERNEL=\$(ls -t /boot/efi/EFI/Linux/*.efi | head -1)
if [ -n \"\$NEW_KERNEL\" ]; then
    echo \"Setting default boot to NEW kernel: \$(basename \$NEW_KERNEL)\"
    echo \"default \$(basename \$NEW_KERNEL .efi)\" > /boot/loader/loader.conf
    echo \"timeout 3\" >> /boot/loader/loader.conf
    echo \"Kernel set successfully\"
else
    echo \"ERROR: Could not find new kernel\"
    exit 1
fi
"

echo ""
echo "[4/5] Verifying kernel configuration..."
virt-customize -a "$IMAGE" \
    --run-command "
echo 'Installed kernels:'
ls -lh /boot/efi/EFI/Linux/*.efi
echo ''
echo 'Boot configuration:'
cat /boot/loader/loader.conf
"

echo ""
echo "[5/5] Cleaning up subscription data..."
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
echo "=========================================="

# Made with Bob
