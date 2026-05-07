#!/bin/bash
# Run boot health validation INSIDE a QCOW2 image
# This uses virt-customize to execute the validation script inside the image

set -e

if [ $# -ne 1 ]; then
    echo "Usage: $0 <qcow2-image-path>"
    echo ""
    echo "Example:"
    echo "  $0 /home/gcoon/.local/share/libvirt/images/rhel97-ks-READONLY.qcow2"
    exit 1
fi

IMAGE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATION_SCRIPT="$SCRIPT_DIR/validate-boot-health-internal.sh"

if [ ! -f "$IMAGE" ]; then
    echo "ERROR: Image not found: $IMAGE"
    exit 1
fi

if [ ! -f "$VALIDATION_SCRIPT" ]; then
    echo "ERROR: Validation script not found: $VALIDATION_SCRIPT"
    exit 1
fi

echo "=========================================="
echo "Running Boot Health Validation"
echo "=========================================="
echo "Image: $IMAGE"
echo "Validation script: $VALIDATION_SCRIPT"
echo ""
echo "This will:"
echo "  1. Copy validation script into image"
echo "  2. Execute it inside the image"
echo "  3. Use pesign from inside the image"
echo ""

# Use podman with the coco-podvm container to run virt-customize
# This ensures we have all the libguestfs tools available
podman run --rm --privileged \
    -v "$IMAGE:/disk.qcow2" \
    -v "$VALIDATION_SCRIPT:/validation.sh:ro" \
    -v /lib/modules:/lib/modules:ro \
    -v /boot:/boot:ro \
    localhost/coco-podvm:latest \
    virt-customize -a /disk.qcow2 \
        --copy-in /validation.sh:/tmp \
        --run-command "chmod +x /tmp/validation.sh && /tmp/validation.sh" \
        --selinux-relabel

echo ""
echo "=========================================="
echo "✓ Validation Complete"
echo "=========================================="

# Made with Bob
