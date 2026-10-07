#!/bin/bash
# IBM patch of upstream create-scratch.sh
# Changes from upstream (tracked in UPSTREAM_DEVIATIONS.md):
#   - set -euo pipefail: exits on any unhandled error
#   - umask 077 before key generation: key file is root-only (upstream: world-readable 0644)
#   - assert $sda non-empty after repart: explicit failure if repart created nothing
#   - assert /dev/mapper/scratch after luksOpen: explicit failure if device not available
set -euo pipefail

KEY_PATH=/run/lukspw.bin
WORKDIR=$(mktemp -d)

# umask 077: key file must be root-readable only.
# Upstream omits this; systemd-repart warns "/run/lukspw.bin has 0644 mode that is too permissive".
umask 077
dd if=/dev/urandom of=$KEY_PATH bs=64 count=1
echo "Random key generated in $KEY_PATH"

echo "[Partition]
Type=linux-generic
Label=scratch
Encrypt=key-file
Format=ext4" > $WORKDIR/scratch.conf

out=$(SYSTEMD_LOG_LEVEL=debug systemd-repart --dry-run=no --key-file=$KEY_PATH --definitions=$WORKDIR --no-pager --json=pretty)

echo $out

sda=$(echo $out | jq -r '.[] | select(.activity=="create") | .node')

echo $sda

# Assert repart actually created a partition (fails if linux-generic already exists)
if [[ -z "$sda" ]]; then
    echo "ERROR: systemd-repart created no scratch partition" >&2
    echo "       This means a linux-generic partition already exists (e.g. rhsm-rw)." >&2
    echo "       systemd-repart matched the existing partition instead of creating scratch." >&2
    echo "       Fix: ensure no linux-generic partition exists in the base image." >&2
    rm -rf $WORKDIR
    exit 1
fi

cryptsetup luksOpen $sda scratch --key-file $KEY_PATH

# Assert the mapped device is available before returning success
if [[ ! -b /dev/mapper/scratch ]]; then
    echo "ERROR: /dev/mapper/scratch not present after luksOpen" >&2
    rm -rf $WORKDIR
    exit 1
fi

rm -rf $WORKDIR

echo "Process completed."
