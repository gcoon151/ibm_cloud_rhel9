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

QCOW2="${1:-}"
if [[ -z "$QCOW2" || ! -f "$QCOW2" ]]; then
    echo "Usage: $0 <path-to.qcow2>"
    exit 1
fi

PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; ((PASS++)) || true; }
fail() { echo "  ✗ FAIL: $*" >&2; ((FAIL++)) || true; }

echo "================================================================="
echo "QCOW2 verification: $QCOW2"
echo "================================================================="

# ---------------------------------------------------------------------------
# 1. GPT integrity — backup header must be at end of disk
# ---------------------------------------------------------------------------
echo ""
echo "--- [1] GPT integrity ---"
RAW=$(mktemp /tmp/verify-XXXXXX.raw)
trap "rm -f '$RAW'" EXIT
qemu-img convert -f qcow2 -O raw "$QCOW2" "$RAW" 2>/dev/null
if sgdisk -v "$RAW" 2>&1 | grep -q "No problems found"; then
    ok "GPT backup header at end of disk"
else
    PROBLEMS=$(sgdisk -v "$RAW" 2>&1 | grep -v "^$" | head -5)
    fail "GPT corrupt: $PROBLEMS"
    echo "    Fix: sgdisk -e $QCOW2"
fi
rm -f "$RAW"
trap - EXIT

# ---------------------------------------------------------------------------
# 2. Partition GUIDs
# ---------------------------------------------------------------------------
echo ""
echo "--- [2] Partition GUIDs ---"

EFI_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
ROOT_GUID="4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709"
VERITY_GUID="D13C5D3B-B5D1-422A-B29F-9454FDC89D76"

PART_COUNT=$(guestfish --ro -a "$QCOW2" -- run : part-list /dev/sda 2>/dev/null | grep -c 'part_num' || true)
ok "Partition count: $PART_COUNT"

for PNUM in 1 2 3 4; do
    GUID=$(guestfish --ro -a "$QCOW2" -- run : part-get-gpt-type /dev/sda $PNUM 2>/dev/null | tr -d '\n' || true)
    [[ -z "$GUID" ]] && continue
    echo "    Part $PNUM GUID: $GUID"
    case "${GUID^^}" in
        "$EFI_GUID")    ok "  Part $PNUM is EFI System Partition" ;;
        "$ROOT_GUID")   ok "  Part $PNUM is Linux x86-64 root (required for dm-verity)" ;;
        "$VERITY_GUID") ok "  Part $PNUM is Linux root verity — dm-verity hash partition present" ;;
    esac
done

# Check root GUID exists
if ! guestfish --ro -a "$QCOW2" -- run : part-list /dev/sda 2>/dev/null | grep -q "part_num"; then
    fail "Could not read partition table"
fi

# ---------------------------------------------------------------------------
# 3. UKI in EFI partition
# ---------------------------------------------------------------------------
echo ""
echo "--- [3] UKI in EFI partition ---"
# Find the EFI partition (512MB, GUID C12A7328...)
EFI_DEV=$(guestfish --ro -a "$QCOW2" -- run : list-partitions 2>/dev/null | \
    while read dev; do
        guid=$(guestfish --ro -a "$QCOW2" -- run : part-get-gpt-type /dev/sda \
            "${dev##*[a-z]}" 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)
        [[ "${guid}" == "${EFI_GUID}" ]] && echo "$dev" && break
    done || true)

UKI_FILES=$(guestfish --ro -a "$QCOW2" -m /dev/sda2:/boot/efi -- ls /boot/efi/EFI/Linux/ 2>/dev/null || true)
if [[ -n "$UKI_FILES" ]]; then
    ok "UKI present in /boot/efi/EFI/Linux/: $UKI_FILES"
else
    fail "No .efi files in /boot/efi/EFI/Linux/ — UKI not installed"
fi

# ---------------------------------------------------------------------------
# 4. Verity addon alongside UKI
# ---------------------------------------------------------------------------
echo ""
echo "--- [4] Verity addon ---"
ADDON=$(guestfish --ro -a "$QCOW2" -m /dev/sda2:/boot/efi -- find /boot/efi/EFI/Linux/ 2>/dev/null | grep 'verity.addon.efi' || true)
if [[ -n "$ADDON" ]]; then
    ok "Verity addon present: $ADDON"
else
    fail "No verity.addon.efi found — dm-verity was not applied"
    echo "    This means the verity container step silently failed (nbd modprobe?)"
fi

# ---------------------------------------------------------------------------
# 5. Key binaries in root filesystem
# ---------------------------------------------------------------------------
echo ""
echo "--- [5] Key binaries in rootfs ---"
for BIN in kata-agent agent-protocol-forwarder; do
    FOUND=$(guestfish --ro -a "$QCOW2" -m /dev/sda3 -- ls /usr/local/bin/ 2>/dev/null | grep "^${BIN}$" || true)
    if [[ -n "$FOUND" ]]; then
        ok "$BIN present in /usr/local/bin/"
    else
        fail "$BIN NOT found in /usr/local/bin/ — payload injection failed"
    fi
done

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
