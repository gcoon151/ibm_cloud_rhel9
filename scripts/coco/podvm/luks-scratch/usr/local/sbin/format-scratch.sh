#!/bin/bash

LUKS_DEV="/dev/disk/by-partlabel/scratch"
MOUNT_POINT="/kata-containers"
MAPPER_NAME="scratch"
KEY_PATH=/run/lukspw.bin

echo "Formatting $LUKS_DEV into LUKS..."

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