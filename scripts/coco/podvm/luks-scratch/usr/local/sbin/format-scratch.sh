#!/bin/bash
# format-scratch.sh — unconditionally create and format the LUKS scratch partition.
#
# Previously luks-scratch.service depended on systemd-repart.service (the system unit).
# The system systemd-repart.service has a trigger condition: it only runs when dm-verity
# is active (roothash= present in kernel cmdline). On IBM Cloud, verity.addon.efi is
# rejected by Secure Boot, so the kernel cmdline has no roothash=, dm-verity is
# bypassed, systemd-repart is skipped, the scratch device never appears, luks-scratch
# never starts, and kata-agent (Requires=luks-scratch) never starts.
#
# Fix: call systemd-repart directly here, bypassing the trigger condition.
# The repart.d config at /usr/lib/repart.d/ (installed by luks-config.tar.gz) describes
# a single 256 MB linux-generic partition labelled "scratch". Running systemd-repart
# with --definitions pointing there unconditionally creates it on every boot.
#
# See UPSTREAM_DEVIATIONS.md deviation O-4.

set -euo pipefail

LUKS_DEV="/dev/disk/by-partlabel/scratch"
MOUNT_POINT="/kata-containers"
MAPPER_NAME="scratch"
KEY_PATH=/run/lukspw.bin

# ---------------------------------------------------------------------------
# Step 1: Create the scratch partition unconditionally via systemd-repart.
# Detect the root disk device (IBM Cloud uses vda, local QEMU may use vda or sda).
# ---------------------------------------------------------------------------
echo "Detecting root disk for scratch partition creation..."
# Try to find the disk that holds the root filesystem
ROOT_DISK=""
for disk in /dev/vda /dev/sda; do
    if [[ -b "$disk" ]]; then
        ROOT_DISK="$disk"
        break
    fi
done
if [[ -z "$ROOT_DISK" ]]; then
    echo "ERROR: Could not find root disk (tried /dev/vda, /dev/sda)" >&2
    exit 1
fi
echo "Root disk: $ROOT_DISK"

echo "Running systemd-repart to create scratch partition..."
if ! systemd-repart \
        --dry-run=no \
        --definitions=/usr/lib/repart.d \
        --discard=no \
        "$ROOT_DISK"; then
    echo "ERROR: systemd-repart failed to create scratch partition" >&2
    exit 1
fi

# Wait for the partition label to appear via udev
echo "Waiting for scratch partition label to appear..."
DEADLINE=$(( $(date +%s) + 15 ))
while [[ ! -e "$LUKS_DEV" ]]; do
    if [[ $(date +%s) -gt $DEADLINE ]]; then
        echo "ERROR: $LUKS_DEV did not appear within 15 s after systemd-repart" >&2
        lsblk "$ROOT_DISK" >&2 || true
        exit 1
    fi
    sleep 1
done
echo "Scratch partition present: $(readlink -f $LUKS_DEV)"

# ---------------------------------------------------------------------------
# Step 2: Format and open the scratch partition as LUKS.
# ---------------------------------------------------------------------------
echo "Formatting $LUKS_DEV as LUKS..."

dd if=/dev/urandom of=$KEY_PATH bs=64 count=1
chmod 600 $KEY_PATH
echo "Random key generated in $KEY_PATH"

# --pbkdf pbkdf2 --pbkdf-force-iterations 1000: the key is random and lives only
# in /run (discarded at power-off), so LUKS2's default Argon2id KDF adds nothing
# but overhead. On local NVMe, Argon2id defaults take ~7.4 s for luksFormat +
# ~2 s for luksOpen. On IBM Cloud network storage (~30 MB/s) the mkfs dominates
# instead. Using pbkdf2-1000 drops KDF overhead to <100 ms at any disk speed.
# See UPSTREAM_DEVIATIONS.md deviation O-1 and docs/SCRATCH_INVESTIGATION_2026-10-09.md
if ! cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    --batch-mode "$LUKS_DEV" --key-file $KEY_PATH; then
    echo "ERROR: Failed to luksFormat $LUKS_DEV. Aborting."
    exit 1
fi
echo "$LUKS_DEV formatted with key $KEY_PATH"

if ! cryptsetup luksOpen "$LUKS_DEV" "$MAPPER_NAME" --key-file $KEY_PATH; then
    echo "ERROR: Failed to luksOpen $LUKS_DEV. Aborting."
    exit 1
fi
echo "$LUKS_DEV opened /dev/mapper/$MAPPER_NAME"

# -m 0: no reserved blocks on ephemeral scratch
# nodiscard,lazy_itable_init=1,lazy_journal_init=1: skip journal zeroing and
# inode table pre-initialization — safe for ephemeral storage and saves ~1-2 s
# on slow IBM Cloud storage.
if ! mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 "/dev/mapper/$MAPPER_NAME"; then
    echo "ERROR: Failed to create ext4 on /dev/mapper/$MAPPER_NAME. Aborting."
    exit 1
fi
echo "Created ext4 filesystem on /dev/mapper/$MAPPER_NAME"

echo "Process completed."
