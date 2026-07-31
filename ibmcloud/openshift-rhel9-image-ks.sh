#!/bin/bash
# -----------------------------------------------------------------------------
# rhel-dm.sh
#
# End-to-end script to build a RHEL 9 Azure CVM qcow2 image equivalent to
# rhel-dm.ks — without needing virt-install + ISO.
#
# Steps:
#   1. Create a 100G empty qcow2
#   2. Expose via qemu-nbd and partition (replicates %pre)
#   3. Format partitions
#   4. Disconnect nbd
#   5. Run virt-customize to install packages and apply %post steps
#
# Prerequisites:
#   sudo dnf install -y qemu-img qemu-nbd virt-customize
#   sudo modprobe nbd max_part=8
#
# Usage:
#   sudo bash rhel-dm.sh
# -----------------------------------------------------------------------------
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
IMAGE_NAME="${IMAGE_NAME:-rhel9-dm.qcow2}"
IMAGE_SIZE="${IMAGE_SIZE:-100G}"
NBD_DEV="${NBD_DEV:-/dev/nbd0}"
CUSTOMIZE_SCRIPT="$(dirname "$0")/rhel-dm-customize.sh"

# ── Colours for output ────────────────────────────────────────────────────────
info()  { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
ok()    { echo -e "\e[1;32m[ OK ]\e[0m  $*"; }
err()   { echo -e "\e[1;31m[ERR ]\e[0m  $*" >&2; exit 1; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err "This script must be run as root (sudo)."
command -v qemu-img      >/dev/null || err "qemu-img not found. Install: dnf install qemu-img"
command -v qemu-nbd      >/dev/null || err "qemu-nbd not found. Install: dnf install qemu-nbd"
command -v virt-customize >/dev/null || err "virt-customize not found. Install: dnf install guestfs-tools"
command -v sfdisk        >/dev/null || err "sfdisk not found."
command -v mkfs.fat      >/dev/null || err "mkfs.fat not found. Install: dnf install dosfstools"
command -v mkfs.ext4     >/dev/null || err "mkfs.ext4 not found. Install: dnf install e2fsprogs"
[[ -f "$CUSTOMIZE_SCRIPT" ]] || err "Customize script not found: $CUSTOMIZE_SCRIPT"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
cleanup() {
    info "Cleaning up nbd connection..."
    qemu-nbd --disconnect "$NBD_DEV" 2>/dev/null || true
    rmmod nbd 2>/dev/null || true
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Create empty qcow2 image (100G)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 1/5: Creating empty ${IMAGE_SIZE} qcow2 image: ${IMAGE_NAME}"
qemu-img create -f qcow2 "$IMAGE_NAME" "$IMAGE_SIZE"
ok "Image created: $IMAGE_NAME"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Expose qcow2 as block device via qemu-nbd and partition
#         Replicates the kickstart %pre section exactly:
#           sda1: EFI  (C12A7328-...) — 1032192 sectors (~500MB)
#           sda2: root (4F68BCE3-...) — 5242880 sectors (~2.5GB)
#         Remaining space is unallocated and available for LVM/cloud-init growth
# ─────────────────────────────────────────────────────────────────────────────
info "Step 2/5: Loading nbd module and connecting image to ${NBD_DEV}"
modprobe nbd max_part=8
qemu-nbd --connect="$NBD_DEV" "$IMAGE_NAME"

# Wait for the device to be ready
sleep 2
[[ -b "$NBD_DEV" ]] || err "NBD device $NBD_DEV not available after connect."

info "Partitioning ${NBD_DEV} (GPT, matching kickstart %pre)..."
sfdisk --wipe always -X gpt "$NBD_DEV" << 'EOF'
2048,1032192,C12A7328-F81F-11D2-BA4B-00A0C93EC93B
,5242880,4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
EOF

# Re-read partition table
partprobe "$NBD_DEV" 2>/dev/null || true
sleep 1

# Fix root partition GUID (replicates kickstart %post first line)
info "Fixing root partition GUID..."
sfdisk --part-type "$NBD_DEV" 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709

ok "Partitioning complete."

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Format partitions
#           sda1 → FAT32 (EFI System Partition)
#           sda2 → ext4  (Linux root)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 3/5: Formatting partitions..."

# Wait for partition devices to appear
sleep 2
[[ -b "${NBD_DEV}p1" ]] || err "Partition ${NBD_DEV}p1 not found."
[[ -b "${NBD_DEV}p2" ]] || err "Partition ${NBD_DEV}p2 not found."

mkfs.fat -F32 "${NBD_DEV}p1"
ok "EFI partition formatted: ${NBD_DEV}p1 → FAT32"

mkfs.ext4 "${NBD_DEV}p2"
ok "Root partition formatted: ${NBD_DEV}p2 → ext4"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Disconnect nbd (virt-customize needs exclusive access)
# ─────────────────────────────────────────────────────────────────────────────
info "Step 4/5: Disconnecting ${NBD_DEV}..."
qemu-nbd --disconnect "$NBD_DEV"
sleep 1
ok "NBD disconnected."

# Disable trap now — nbd already disconnected
trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Run virt-customize to install packages and apply %post
# ─────────────────────────────────────────────────────────────────────────────
info "Step 5/5: Running virt-customize (packages + %post)..."
virt-customize \
    -a "$IMAGE_NAME" \
    --hostname "localhost.localdomain" \
    --timezone "Etc/UTC" \
    --selinux-relabel \
    --run "$CUSTOMIZE_SCRIPT"

ok "virt-customize completed."

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────
echo ""
ok "Image build complete: $(pwd)/${IMAGE_NAME}"
echo ""
echo "  Verify with:  qemu-img info ${IMAGE_NAME}"
echo "  Inspect with: virt-filesystems -a ${IMAGE_NAME} --all --long -h"
