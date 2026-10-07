#!/usr/bin/env bash
# =============================================================================
# verify-qcow2.sh
#
# Mandatory local verification of a peer pod QCOW2 before uploading to IBM Cloud.
# ALL checks must pass. Any failure exits non-zero and prints what is missing.
#
# Usage:
#   ./scripts/verify-qcow2.sh <path-to.qcow2>
#
# Run this on the build host (gcoon@192.168.1.196) after every build,
# BEFORE running upload_hl_dev_cos_bucket.sh.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Args + options
# ---------------------------------------------------------------------------
# --min-binary-date YYYY-MM-DD  reject if CDH/AA binaries are older than this
#                               (default: 2026-07-24, the date of payload 1.13.1 binaries)
# --payload-tag TAG             expected payload tag string to find in manifest (optional)
# ---------------------------------------------------------------------------
QCOW2=""
MIN_BINARY_DATE="2026-07-24"
EXPECTED_PAYLOAD_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-binary-date) MIN_BINARY_DATE="$2"; shift 2 ;;
        --payload-tag)     EXPECTED_PAYLOAD_TAG="$2"; shift 2 ;;
        -*)  echo "Unknown option: $1" >&2; exit 1 ;;
        *)   QCOW2="$1"; shift ;;
    esac
done

if [[ -z "$QCOW2" || ! -f "$QCOW2" ]]; then
    echo "Usage: $0 <path-to.qcow2> [--min-binary-date YYYY-MM-DD] [--payload-tag TAG]"
    exit 1
fi

MIN_BINARY_EPOCH=$(date -d "$MIN_BINARY_DATE" +%s 2>/dev/null || \
                   python3 -c "import datetime; print(int(datetime.datetime.strptime('$MIN_BINARY_DATE','%Y-%m-%d').timestamp()))")

PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; ((PASS++)) || true; }
fail() { echo "  ✗ FAIL: $*" >&2; ((FAIL++)) || true; }
warn() { echo "  ⚠ WARN: $*"; }

echo "================================================================="
echo "QCOW2 verification: $QCOW2"
echo "================================================================="

# ---------------------------------------------------------------------------
# 1. GPT integrity — backup header must be at end of disk
# ---------------------------------------------------------------------------
# GPT backup header corruption is a real recurring bug (deviation #9: sgdisk -e
# needed twice). This check has caught real defects. Run with sudo so nbd is
# available. If nbd is genuinely unavailable, print SKIP and count as FAIL —
# a skipped check must never count as passed.
echo ""
echo "--- [1] GPT integrity ---"
GPT_NBD=/dev/nbd0
GPT_SKIP=0
if ! sudo modprobe nbd max_part=8 2>/dev/null; then
    echo "  SKIP: could not load nbd module — GPT check cannot run" >&2
    ((FAIL++)) || true
    GPT_SKIP=1
fi
if [[ $GPT_SKIP -eq 0 ]]; then
    # Trap to ensure nbd is always disconnected
    _nbd_cleanup() { sudo qemu-nbd --disconnect "$GPT_NBD" 2>/dev/null || true; }
    trap '_nbd_cleanup' EXIT
    if ! sudo qemu-nbd --read-only --connect="$GPT_NBD" "$QCOW2" 2>/dev/null; then
        echo "  SKIP: qemu-nbd connect failed — GPT check cannot run" >&2
        ((FAIL++)) || true
        GPT_SKIP=1
    else
        # Let the kernel finish scanning the device before reading the partition table
        sudo udevadm settle 2>/dev/null || true
        sleep 1
    fi
fi
if [[ $GPT_SKIP -eq 0 ]]; then
    GPT_OUT=$(sudo sgdisk -v "$GPT_NBD" 2>&1 || true)
    _nbd_cleanup
    trap - EXIT
    if echo "$GPT_OUT" | grep -q "No problems found"; then
        ok "GPT integrity verified (sgdisk -v: No problems found)"
    else
        fail "GPT check failed: $GPT_OUT"
    fi
else
    trap - EXIT 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 2. Partition GUIDs
# ---------------------------------------------------------------------------
echo ""
echo "--- [2] Partition GUIDs ---"

EFI_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
ROOT_GUID="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"
# V3 fix: x86-64 root verity GUID (not 32-bit x86 D13C5D3B...).
# Verified from RHEL 10 image: 2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5
VERITY_GUID="2C7357ED-EBD2-46D9-AEC1-23D437EC2BF5"
VERITY_FOUND=0

PART_COUNT=$(guestfish --ro -a "$QCOW2" -- run : part-list /dev/sda 2>/dev/null | grep -c 'part_num' || true)
ok "Partition count: $PART_COUNT"

for PNUM in 1 2 3 4; do
    GUID=$(guestfish --ro -a "$QCOW2" -- run : part-get-gpt-type /dev/sda $PNUM 2>/dev/null | tr -d '\n' || true)
    [[ -z "$GUID" ]] && continue
    echo "    Part $PNUM GUID: $GUID"
    case "${GUID^^}" in
        "$EFI_GUID")    ok "  Part $PNUM is EFI System Partition" ;;
        "$ROOT_GUID")   ok "  Part $PNUM is Linux x86-64 root (required for dm-verity)" ;;
        "$VERITY_GUID") ok "  Part $PNUM is Linux x86-64 root verity — dm-verity hash partition present"; VERITY_FOUND=1 ;;
    esac
done

# V3 fix: verity partition is REQUIRED — fail if absent
if [[ $VERITY_FOUND -eq 0 ]]; then
    fail "No x86-64 root verity partition (GUID $VERITY_GUID) found — dm-verity was not applied"
fi

# Fix 4: assert no linux-generic (0FC63DAF) partition exists in the finished image.
# A linux-generic partition (e.g. old rhsm-rw from deviation #14) causes systemd-repart
# to match it instead of creating the encrypted scratch disk — kata-agent then fails
# because /dev/mapper/scratch never appears. The base image must have no such partition.
LINUX_GENERIC_FOUND=0
for PNUM in 1 2 3 4; do
    GUID=$(guestfish --ro -a "$QCOW2" -- run : part-get-gpt-type /dev/sda $PNUM 2>/dev/null | tr -d '\n' | tr '[:lower:]' '[:upper:]' || true)
    [[ -z "$GUID" ]] && continue
    if [[ "${GUID}" == "0FC63DAF-8483-4772-8E79-3D69D8477DE4" ]]; then
        LINUX_GENERIC_FOUND=1
        fail "Part $PNUM has linux-generic GUID (0FC63DAF) — repart will match this instead of creating scratch"
    fi
done
[[ $LINUX_GENERIC_FOUND -eq 0 ]] && ok "No linux-generic partition — systemd-repart scratch creation unblocked"

# Check root GUID exists
if ! guestfish --ro -a "$QCOW2" -- run : part-list /dev/sda 2>/dev/null | grep -q "part_num"; then
    fail "Could not read partition table"
fi

# ---------------------------------------------------------------------------
# 3. UKI in EFI partition
# ---------------------------------------------------------------------------
# V2 fix: mount EFI partition at / inside guestfish (no /boot/efi mountpoint
# on the EFI partition itself). Previously used -m /dev/sda1:/boot/efi which
# gave "mount point is not a directory" (hidden by 2>/dev/null) and falsely
# reported UKI/addon missing when they were present (seen in C-15 verify).
echo ""
echo "--- [3] UKI in EFI partition ---"
UKI_FILES=$(guestfish --ro -a "$QCOW2" -- \
    run : mount /dev/sda1 / : find /EFI/Linux 2>/dev/null | grep '\.efi$' || true)
if [[ -n "$UKI_FILES" ]]; then
    ok "UKI present in EFI/Linux: $(echo "$UKI_FILES" | tr '\n' ' ')"
else
    fail "No .efi files in EFI/Linux — UKI not installed"
fi

# ---------------------------------------------------------------------------
# 4. Verity addon alongside UKI
# ---------------------------------------------------------------------------
echo ""
echo "--- [4] Verity addon ---"
# V2 fix: same mount fix as section 3
ADDON=$(guestfish --ro -a "$QCOW2" -- \
    run : mount /dev/sda1 / : find /EFI/Linux 2>/dev/null | grep 'verity\.addon\.efi' || true)
if [[ -n "$ADDON" ]]; then
    ok "Verity addon present: $ADDON"
else
    fail "No verity.addon.efi found — dm-verity was not applied"
    echo "    This means the verity container step silently failed (nbd modprobe?)"
fi

# ---------------------------------------------------------------------------
# 5. Key binaries in root filesystem
# ---------------------------------------------------------------------------
# Find the root partition by GUID (4F68BCE3...) — do not hardcode /dev/sda3.
# Layout is EFI=p1, root=p2, verity=p3 (3-partition) or EFI=p1, root=p2,
# luks-scratch=p3, verity=p4 (4-partition). Always look up by type GUID.
ROOT_PART=""
for PNUM in 2 3 4; do
    GUID=$(guestfish --ro -a "$QCOW2" -- run : part-get-gpt-type /dev/sda $PNUM 2>/dev/null | tr -d '\n' | tr '[:lower:]' '[:upper:]' || true)
    if [[ "${GUID}" == "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" ]]; then
        ROOT_PART="/dev/sda${PNUM}"
        break
    fi
done
if [[ -z "$ROOT_PART" ]]; then
    fail "Cannot find root partition by GUID 4F68BCE3... — partition table unexpected"
    ROOT_PART="/dev/sda2"  # best-guess fallback so remaining checks still run
fi
ok "Root partition: $ROOT_PART"

echo ""
echo "--- [5] Key binaries in rootfs ---"
for BIN in kata-agent agent-protocol-forwarder; do
    FOUND=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- ls /usr/local/bin/ 2>/dev/null | grep "^${BIN}$" || true)
    if [[ -n "$FOUND" ]]; then
        ok "$BIN present in /usr/local/bin/"
    else
        fail "$BIN NOT found in /usr/local/bin/ — payload injection failed"
    fi
done

# Post-check: assert create-scratch.sh in the image is our patched version.
# The upstream version has no error handling and exits 0 on failure.
# This check confirms the luks-scratch tarball was built from the patched source.
SCRATCH_PATCHED=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- \
    cat /usr/local/sbin/create-scratch.sh 2>/dev/null | grep -c 'set -euo pipefail' || true)
if [[ "${SCRATCH_PATCHED}" -ge 1 ]]; then
    ok "create-scratch.sh is patched (set -euo pipefail present)"
else
    fail "create-scratch.sh is NOT patched — upstream version in image; scratch failures will be hidden"
fi

# ---------------------------------------------------------------------------
# 5b. SSH daemon check — warn if sshd is absent/masked (debug images need it)
# ---------------------------------------------------------------------------
echo ""
echo "--- [5b] SSH daemon ---"
SSHD_BIN=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- ls /usr/sbin/ 2>/dev/null | grep "^sshd$" || true)
SSHD_MASKED=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- readlink /etc/systemd/system/sshd.service 2>/dev/null || true)
if [[ -z "$SSHD_BIN" ]]; then
    warn "sshd NOT installed — SSH into the VM will not work"
elif echo "$SSHD_MASKED" | grep -q "/dev/null"; then
    warn "sshd is MASKED — SSH into the VM will not work (hardened image)"
else
    ok "sshd installed and not masked"
fi

# ---------------------------------------------------------------------------
# 6. Version manifest + payload assertions
# ---------------------------------------------------------------------------
echo ""
echo "--- [6] Version manifest + payload assertions ---"
MANIFEST=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- cat /etc/podvm-version.json 2>/dev/null || true)

if [[ -z "$MANIFEST" ]]; then
    fail "No /etc/podvm-version.json — cannot verify payload versions. Image predates manifest or build failed."
    echo "    This is a hard gate. Do not upload images without a version manifest."
else
    ok "Version manifest present"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "$MANIFEST" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    rows = [
        ('Build date',          d.get('build_date','?')),
        ('RHEL version',        d.get('rhel_version','?')),
        ('Kernel',              d.get('kernel_version','?')),
        ('UKI filename',        d.get('uki_filename','?')),
        ('Payload image',       d.get('payload_image','?')),
        ('Payload digest',      d.get('payload_digest','?')),
        ('Pause bundle image',  d.get('pause_bundle_image','?')),
        ('CDH binary date',     d.get('cdh_binary_date','?')),
        ('AA binary date',      d.get('aa_binary_date','?')),
        ('kata-agent date',     d.get('kata_agent_binary_date','?')),
    ]
    for label, val in rows:
        print(f'  │  {label:<24} {val}')
except Exception as e:
    print(f'  │  (parse error: {e})')
"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""

    # --- Assert CDH binary date >= MIN_BINARY_DATE ---
    CDH_DATE=$(echo "$MANIFEST" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('cdh_binary_date','unknown'))
except: print('unknown')
" 2>/dev/null)
    AA_DATE=$(echo "$MANIFEST" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('aa_binary_date','unknown'))
except: print('unknown')
" 2>/dev/null)

    for LABEL_DATE in "CDH:$CDH_DATE" "AA:$AA_DATE"; do
        LABEL="${LABEL_DATE%%:*}"
        BDATE="${LABEL_DATE#*:}"
        if [[ "$BDATE" == "unknown" ]]; then
            fail "$LABEL binary date unknown in manifest — payload injection may have failed"
        else
            BEPOCH=$(date -d "$BDATE" +%s 2>/dev/null || \
                     python3 -c "import datetime; print(int(datetime.datetime.strptime('$BDATE','%Y-%m-%d').timestamp()))")
            if [[ "$BEPOCH" -lt "$MIN_BINARY_EPOCH" ]]; then
                fail "$LABEL binary date $BDATE is older than required minimum $MIN_BINARY_DATE — stale payload was injected (see Lesson 20)"
            else
                ok "$LABEL binary date $BDATE >= $MIN_BINARY_DATE"
            fi
        fi
    done

    # --- Assert payload tag if specified ---
    if [[ -n "$EXPECTED_PAYLOAD_TAG" ]]; then
        ACTUAL_PAYLOAD=$(echo "$MANIFEST" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('payload_image',''))
except: print('')
" 2>/dev/null)
        if echo "$ACTUAL_PAYLOAD" | grep -q "$EXPECTED_PAYLOAD_TAG"; then
            ok "Payload image contains expected tag '$EXPECTED_PAYLOAD_TAG': $ACTUAL_PAYLOAD"
        else
            fail "Payload image '$ACTUAL_PAYLOAD' does not contain expected tag '$EXPECTED_PAYLOAD_TAG'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
echo "Result: $PASS passed, $FAIL failed"
echo "================================================================="

if [[ $FAIL -gt 0 ]]; then
    echo "❌ QCOW2 is NOT ready for upload. Fix the failures above first."
    exit 1
else
    echo "✓ QCOW2 passed all checks. Safe to upload."
    exit 0
fi
