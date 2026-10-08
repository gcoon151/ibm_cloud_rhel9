#!/bin/bash
# IBM patch of upstream create-scratch.sh
# Runs at boot inside the peer pod VM as ExecStart for luks-scratch.service.
#
# Changes from upstream (tracked in UPSTREAM_DEVIATIONS.md):
#   - set -euo pipefail: exits on any unhandled error
#   - umask 077 before key generation: key file is root-only (upstream: world-readable 0644)
#   - Separate repart (partition create) from LUKS (format+open+mkfs):
#       repart conf only specifies Type/Label, NOT Encrypt/Format.
#       cryptsetup and mkfs.ext4 run explicitly here with optimised flags.
#   - pbkdf2-1000: key is random and discarded at power-off; Argon2id adds ~9 s overhead
#       for zero security benefit. pbkdf2-1000 drops KDF overhead to <100 ms.
#   - mkfs lazy flags: -m 0, nodiscard, lazy_itable_init=1, lazy_journal_init=1
#       saves ~1-2 s on slow IBM Cloud storage; safe for ephemeral scratch.
#   - No SizeMaxBytes cap: partition fills remaining free space. Benchmarked durations
#       with pbkdf2 + lazy mkfs are dominated by sequential write speed, not partition
#       size. Measure before capping; a cap that's too small causes ENOSPC on image pull.
#   - Start/end timestamps: luks-scratch duration appears in every boot log.
#   - assert $sda non-empty after repart: explicit failure if repart created nothing
#   - assert /dev/mapper/scratch after luksOpen: explicit failure if device not available
#
# See UPSTREAM_DEVIATIONS.md deviations O-1, O-3, O-4.
set -euo pipefail

T0=$(date +%s%3N)
echo "[luks-scratch] START $(date -u +%T.%3N)"

KEY_PATH=/run/lukspw.bin
WORKDIR=$(mktemp -d)

# umask 077: key file must be root-readable only.
# Upstream omits this; systemd-repart warns "/run/lukspw.bin has 0644 mode that is too permissive".
umask 077
dd if=/dev/urandom of=$KEY_PATH bs=64 count=1
echo "[luks-scratch] Random key generated in $KEY_PATH"

# ---------------------------------------------------------------------------
# Step 1: Create the scratch partition via systemd-repart.
# repart conf intentionally does NOT include Encrypt= or Format= —
# those are handled below with optimised flags that repart doesn't support.
# ---------------------------------------------------------------------------
echo "[Partition]
Type=linux-generic
Label=scratch" > $WORKDIR/scratch.conf

out=$(SYSTEMD_LOG_LEVEL=debug systemd-repart --dry-run=no --definitions=$WORKDIR --no-pager --json=pretty)

echo $out

sda=$(echo $out | jq -r '.[] | select(.activity=="create") | .node')

echo "[luks-scratch] Partition node: $sda"

# Assert repart actually created a partition (fails if linux-generic already exists,
# e.g. from a previous boot or a stale partition left by a failed run).
if [[ -z "$sda" ]]; then
    echo "ERROR: systemd-repart created no scratch partition" >&2
    echo "       If a linux-generic partition already exists, repart matched it instead." >&2
    echo "       Check: lsblk -o NAME,PARTTYPE,LABEL" >&2
    rm -rf $WORKDIR
    exit 1
fi

rm -rf $WORKDIR

T1=$(date +%s%3N)
echo "[luks-scratch] Partition created in $(( T1 - T0 )) ms"

# ---------------------------------------------------------------------------
# Step 2: LUKS format + open.
# --pbkdf pbkdf2 --pbkdf-force-iterations 1000:
#   Key is random, ephemeral (lives only in /run, discarded at power-off, never reused).
#   Argon2id's memory-hard KDF resists offline dictionary attacks against a stolen key —
#   none of that applies here. Argon2id defaults benchmark at ~7.4 s luksFormat +
#   ~2 s luksOpen on NVMe. pbkdf2-1000 drops that to <100 ms at any disk speed.
# ---------------------------------------------------------------------------
echo "[luks-scratch] Running luksFormat on $sda..."
cryptsetup luksFormat --type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha256 \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    --batch-mode "$sda" --key-file "$KEY_PATH"

T2=$(date +%s%3N)
echo "[luks-scratch] luksFormat done in $(( T2 - T1 )) ms"

cryptsetup luksOpen "$sda" scratch --key-file "$KEY_PATH"

# Assert the mapped device is available before continuing
if [[ ! -b /dev/mapper/scratch ]]; then
    echo "ERROR: /dev/mapper/scratch not present after luksOpen" >&2
    exit 1
fi

T3=$(date +%s%3N)
echo "[luks-scratch] luksOpen done in $(( T3 - T2 )) ms"

# ---------------------------------------------------------------------------
# Step 3: Format the mapped device as ext4.
# -m 0:                       no reserved blocks (scratch is not a system fs)
# -E nodiscard:               skip TRIM pass (not needed for ephemeral storage)
# -E lazy_itable_init=1:      defer inode table initialisation to background
# -E lazy_journal_init=1:     skip journal zeroing — safe for ephemeral storage
# On IBM Cloud ~30 MB/s storage these flags reduce mkfs time by ~1-2 s.
# ---------------------------------------------------------------------------
mkfs.ext4 -F -m 0 -E nodiscard,lazy_itable_init=1,lazy_journal_init=1 /dev/mapper/scratch

T4=$(date +%s%3N)
echo "[luks-scratch] mkfs.ext4 done in $(( T4 - T3 )) ms"

TOTAL=$(( T4 - T0 ))
echo "[luks-scratch] DONE total=${TOTAL} ms  (repart=$(( T1-T0 )) luksFormat=$(( T2-T1 )) luksOpen=$(( T3-T2 )) mkfs=$(( T4-T3 )))"
echo "Process completed."
