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
REQUIRE_SSHD_MASKED="false"
MIN_BINARY_DATE="2026-07-24"
EXPECTED_PAYLOAD_TAG=""
BOOT_MODE="uki"   # override with --boot-mode grub for grub-chain images

while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-binary-date) MIN_BINARY_DATE="$2"; shift 2 ;;
        --payload-tag)     EXPECTED_PAYLOAD_TAG="$2"; shift 2 ;;
        --boot-mode)       BOOT_MODE="$2"; shift 2 ;;
        --require-sshd-masked) REQUIRE_SSHD_MASKED="true"; shift ;;
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
echo "--- [0] Virtual size is a whole GiB (RHEL 10 / grub mode; Lesson 121) ---"
if [[ "${BOOT_MODE}" == "grub" ]]; then
    VSIZE_BYTES=$(qemu-img info --output json "$QCOW2" | python3 -c 'import sys,json;print(json.load(sys.stdin)["virtual-size"])')
    if (( VSIZE_BYTES % 1073741824 == 0 )); then
        ok "virtual size $VSIZE_BYTES bytes = $(( VSIZE_BYTES / 1073741824 )) GiB (whole GiB: no tail gap on IBM Cloud)"
    else
        fail "virtual size $VSIZE_BYTES is not a whole GiB; IBM Cloud rounds up and the odd remainder becomes a tail gap that repart picks for scratch (Lesson 121)"
    fi
else
    echo "  (skipped: not grub mode)"
fi

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
    # Kill any stale qemu-nbd processes on nbd0 from previous runs (zombies survive EXIT trap)
    sudo kill -9 $(pgrep -f "qemu-nbd.*${GPT_NBD}") 2>/dev/null || true
    sudo qemu-nbd --disconnect "$GPT_NBD" 2>/dev/null || true
    sleep 1
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
    if echo "$GPT_OUT" | grep -q "No problems found"; then
        ok "GPT integrity verified (sgdisk -v: No problems found)"
        _nbd_cleanup
        trap - EXIT
    else
        echo "  GPT check found issues — attempting auto-repair with sgdisk -e..."
        # Disconnect read-only nbd, reconnect read-write, run sgdisk -e on the device
        _nbd_cleanup
        trap - EXIT
        # sgdisk -e needs a writable block device — connect nbd read-write for repair
        if sudo modprobe nbd max_part=8 2>/dev/null && sudo qemu-nbd --connect="$GPT_NBD" "$QCOW2" 2>/dev/null; then
            sudo udevadm settle 2>/dev/null || true
            REPAIR_OUT=$(sudo sgdisk -e "$GPT_NBD" 2>&1 || true)
            sudo qemu-nbd --disconnect "$GPT_NBD" 2>/dev/null || true
            if echo "$REPAIR_OUT" | grep -q "relocated\|The operation has completed successfully"; then
                ok "GPT backup header relocated successfully (sgdisk -e on nbd device)"
            else
                echo "  Retrying GPT check after repair attempt..."
            fi
        else
            echo "  WARN: could not reconnect nbd read-write for repair — will verify only"
        fi
        # Re-verify after repair
        if sudo modprobe nbd max_part=8 2>/dev/null && sudo qemu-nbd --read-only --connect="$GPT_NBD" "$QCOW2" 2>/dev/null; then
            sudo udevadm settle 2>/dev/null || true
            sleep 1
            GPT_OUT2=$(sudo sgdisk -v "$GPT_NBD" 2>&1 || true)
            sudo qemu-nbd --disconnect "$GPT_NBD" 2>/dev/null || true
            if echo "$GPT_OUT2" | grep -q "No problems found"; then
                ok "GPT integrity verified after repair"
            else
                fail "GPT check failed even after sgdisk -e repair: $GPT_OUT2"
            fi
        else
            fail "GPT check failed and could not re-verify after repair: $GPT_OUT"
        fi
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
# grub mode only: XBOOTLDR type for /boot partition (BC13C2FF-59E6-4262-A352-B275FD6F7172)
XBOOTLDR_GUID="BC13C2FF-59E6-4262-A352-B275FD6F7172"
VERITY_FOUND=0
XBOOTLDR_FOUND=0

PART_COUNT=$(guestfish --ro -a "$QCOW2" -- run : part-list /dev/sda 2>/dev/null | grep -c 'part_num' || true)
ok "Partition count: $PART_COUNT"

for PNUM in 1 2 3 4 5; do
    GUID=$(guestfish --ro -a "$QCOW2" -- run : part-get-gpt-type /dev/sda $PNUM 2>/dev/null | tr -d '\n' || true)
    [[ -z "$GUID" ]] && continue
    echo "    Part $PNUM GUID: $GUID"
    case "${GUID^^}" in
        "$EFI_GUID")      ok "  Part $PNUM is EFI System Partition" ;;
        "$ROOT_GUID")     ok "  Part $PNUM is Linux x86-64 root" ;;
        "$VERITY_GUID")   ok "  Part $PNUM is Linux x86-64 root verity"; VERITY_FOUND=1 ;;
        "$XBOOTLDR_GUID") ok "  Part $PNUM is XBOOTLDR /boot (grub mode)"; XBOOTLDR_FOUND=1 ;;
    esac
done

# Verity partition check is RHEL 10 (grub mode) only.
# RHEL 9 (uki mode) does NOT use dm-verity — a verity partition indicates a broken build.
if [[ "${BOOT_MODE}" == "grub" ]]; then
    if [[ $VERITY_FOUND -eq 0 ]]; then
        fail "grub mode: No x86-64 root verity partition (GUID $VERITY_GUID) found — dm-verity was not applied"
    fi
    if [[ $XBOOTLDR_FOUND -eq 0 ]]; then
        fail "grub mode: No XBOOTLDR /boot partition (GUID $XBOOTLDR_GUID) found"
    fi
else
    # uki mode (RHEL 9): verity partition must NOT be present — if it is, APPLY_VERITY was true
    if [[ $VERITY_FOUND -eq 1 ]]; then
        fail "uki mode (RHEL 9): verity partition found — APPLY_VERITY was true during build (check ~/.env and Lessons 101-102)"
    fi
    ok "uki mode (RHEL 9): no verity partition — correct"
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
# 3. Boot chain in EFI partition
# ---------------------------------------------------------------------------
# uki mode:  EFI/Linux/<machine-id>-<ver>.efi + .extra.d/verity.addon.efi
# grub mode: EFI/redhat/shimx64.efi (Microsoft-signed) + EFI/redhat/grubx64.efi (RH-signed)
#            No EFI/Linux UKI should be present in grub mode.
echo ""
if [[ "${BOOT_MODE}" == "grub" ]]; then
    echo "--- [3] Boot chain (grub mode: shim + grubx64) ---"
    SHIM=$(guestfish --ro -a "$QCOW2" -- \
        run : mount /dev/sda1 / : find /EFI/redhat 2>/dev/null | grep 'shimx64\.efi$' || true)
    GRUB=$(guestfish --ro -a "$QCOW2" -- \
        run : mount /dev/sda1 / : find /EFI/redhat 2>/dev/null | grep 'grubx64\.efi$' || true)
    UKI_LEFTOVER=$(guestfish --ro -a "$QCOW2" -- \
        run : mount /dev/sda1 / : find /EFI/Linux 2>/dev/null | grep '\.efi$' || true)
    [[ -n "$SHIM" ]] && ok "shimx64.efi present: $SHIM" || fail "shimx64.efi not found in EFI/redhat — grub boot chain broken"
    [[ -n "$GRUB" ]] && ok "grubx64.efi present: $GRUB" || fail "grubx64.efi not found in EFI/redhat — grub boot chain broken"
    [[ -z "$UKI_LEFTOVER" ]] && ok "No leftover UKI in EFI/Linux (clean grub image)" \
        || fail "Leftover UKI file(s) in EFI/Linux — grub image was not cleaned up: $UKI_LEFTOVER"
else
    echo "--- [3] UKI in EFI partition ---"
    # V2 fix: mount EFI partition at / inside guestfish (no /boot/efi mountpoint
    # on the EFI partition itself). Previously used -m /dev/sda1:/boot/efi which
    # gave "mount point is not a directory" (hidden by 2>/dev/null) and falsely
    # reported UKI/addon missing when they were present (seen in C-15 verify).
    UKI_FILES=$(guestfish --ro -a "$QCOW2" -- \
        run : mount /dev/sda1 / : find /EFI/Linux 2>/dev/null | grep '\.efi$' || true)
    if [[ -n "$UKI_FILES" ]]; then
        ok "UKI present in EFI/Linux: $(echo "$UKI_FILES" | tr '\n' ' ')"
    else
        fail "No .efi files in EFI/Linux — UKI not installed"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Verity roothash delivery
# ---------------------------------------------------------------------------
echo ""
if [[ "${BOOT_MODE}" == "grub" ]]; then
    echo "--- [4] BLS entry with roothash= (grub mode) ---"
    # Find /boot partition by XBOOTLDR GUID
    BOOT_PART=""
    for PNUM in 2 3 4 5; do
        GUID=$(guestfish --ro -a "$QCOW2" -- run : part-get-gpt-type /dev/sda $PNUM 2>/dev/null | tr -d '\n' | tr '[:lower:]' '[:upper:]' || true)
        if [[ "${GUID}" == "BC13C2FF-59E6-4262-A352-B275FD6F7172" ]]; then
            BOOT_PART="/dev/sda${PNUM}"
            break
        fi
    done
    if [[ -z "$BOOT_PART" ]]; then
        fail "Cannot find XBOOTLDR /boot partition — cannot check BLS entries"
    else
        ok "Found /boot partition: $BOOT_PART"
        BLS_ENTRIES=$(guestfish --ro -a "$QCOW2" -- \
            run : mount "$BOOT_PART" / : ls /loader/entries 2>/dev/null | grep '\.conf$' || true)
        BLS_COUNT=$(echo "$BLS_ENTRIES" | grep -c '\.conf' || true)
        if [[ $BLS_COUNT -eq 0 ]]; then
            fail "No BLS entries found in /boot/loader/entries/ — inject_grub_cmdline did not run"
        elif [[ $BLS_COUNT -gt 1 ]]; then
            fail "Multiple BLS entries ($BLS_COUNT) — expected exactly 1 (no rescue entry)"
        else
            ok "Exactly 1 BLS entry: $BLS_ENTRIES"
            # Build the full path: /loader/entries/<filename>
            BLS_ENTRY_PATH="/loader/entries/$(echo "$BLS_ENTRIES" | tr -d '\n')"
            BLS_OPTIONS=$(guestfish --ro -a "$QCOW2" -- \
                run : mount "$BOOT_PART" / : cat "${BLS_ENTRY_PATH}" 2>/dev/null | grep '^options ' || true)
            if echo "$BLS_OPTIONS" | grep -q 'roothash='; then
                ok "BLS entry options contain roothash="
            else
                fail "BLS entry options do NOT contain roothash= — inject_grub_cmdline failed"
                echo "    options line: $BLS_OPTIONS"
            fi
            if echo "$BLS_OPTIONS" | grep -q 'systemd\.verity_root_data='; then
                ok "BLS entry options contain systemd.verity_root_data="
            else
                fail "BLS entry options missing systemd.verity_root_data= PARTUUID"
            fi
            if echo "$BLS_OPTIONS" | grep -q 'root=/dev/mapper/root'; then
                ok "BLS entry options contain root=/dev/mapper/root"
            else
                fail "BLS entry options missing root=/dev/mapper/root"
            fi
            # Initramfs must contain overlay.ko when systemd.volatile=overlay is on the cmdline.
            # A host-only initramfs (dnf kernel update inside virt-customize) lacks it -> boot drops
            # to emergency mode at systemd-volatile-root (rhel10-2026111814, 2026-11-18).
            if echo "$BLS_OPTIONS" | grep -q 'systemd\.volatile=overlay'; then
                INITRD_NAME=$(guestfish --ro -a "$QCOW2" -- \
                    run : mount "$BOOT_PART" / : cat "${BLS_ENTRY_PATH}" 2>/dev/null | awk '/^initrd /{print $2}' | head -1 | xargs -r basename || true)
                INITRD_TMP=$(mktemp /tmp/verify-initrd-XXXXXX)
                if [[ -n "$INITRD_NAME" ]] && guestfish --ro -a "$QCOW2" -- \
                        run : mount "$BOOT_PART" / : download "/${INITRD_NAME}" "$INITRD_TMP" 2>/dev/null \
                        && [[ -s "$INITRD_TMP" ]]; then
                    # capture the listing first: 'grep -q' closing the pipe early + pipefail = false negative
                    # dracut may write a multi-segment initramfs (early cpio + compressed main); zcat cannot read that.
                    if command -v 3cpio >/dev/null 2>&1; then
                        INITRD_LIST=$(3cpio -t "$INITRD_TMP" 2>/dev/null || true)
                    elif command -v lsinitrd >/dev/null 2>&1; then
                        INITRD_LIST=$(lsinitrd "$INITRD_TMP" 2>/dev/null || true)
                    else
                        INITRD_LIST=$(zcat "$INITRD_TMP" 2>/dev/null | cpio -t 2>/dev/null || true)
                    fi
                    if grep -q 'kernel/fs/overlayfs/overlay\.ko' <<<"$INITRD_LIST"; then
                        ok "Initramfs $INITRD_NAME contains overlay.ko (systemd.volatile=overlay can mount)"
                    else
                        fail "Initramfs $INITRD_NAME has NO overlay.ko but cmdline has systemd.volatile=overlay — image will drop to emergency mode"
                    fi
                else
                    fail "Cannot extract initramfs '${INITRD_NAME}' from /boot to check overlay.ko"
                fi
                rm -f "$INITRD_TMP"
            fi
        fi
    fi
else
    # uki mode (RHEL 9): no verity addon expected — skip this check entirely
    echo "--- [4] Verity addon (skipped — uki/RHEL 9 mode does not use dm-verity) ---"
    ok "uki mode: verity.addon.efi check skipped (RHEL 9 does not use dm-verity)"
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

# Post-check: assert scratch script in the image is our patched version.
# RHEL 10 uses create-scratch.sh; RHEL 9 uses format-scratch.sh. Check both.
SCRATCH_PATCHED=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- \
    sh 'grep -c "set -euo pipefail" /usr/local/sbin/create-scratch.sh /usr/local/sbin/format-scratch.sh 2>/dev/null | awk -F: "{s+=\$2} END{print s+0}"' 2>/dev/null || echo 0)
if [[ "${SCRATCH_PATCHED}" -ge 1 ]]; then
    ok "scratch script is patched (set -euo pipefail present)"
else
    fail "scratch script NOT patched — upstream version in image; scratch failures will be hidden"
fi

# ---------------------------------------------------------------------------
# 5b. SSH daemon check — warn if sshd is absent/masked (debug images need it).
#     With --require-sshd-masked (hardened builds) the logic is inverted: sshd.service
#     MUST be a symlink to /dev/null and nothing may enable sshd.service / sshd.socket.
# ---------------------------------------------------------------------------
echo ""
echo "--- [5b] SSH daemon ---"
SSHD_BIN=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- ls /usr/sbin/ 2>/dev/null | grep "^sshd$" || true)
SSHD_MASKED=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- readlink /etc/systemd/system/sshd.service 2>/dev/null || true)
if [[ "$REQUIRE_SSHD_MASKED" == "true" ]]; then
    SSHD_WANTS=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- sh 'ls /etc/systemd/system/*.wants/sshd.service /etc/systemd/system/*.wants/sshd.socket 2>/dev/null' 2>/dev/null || true)
    if echo "$SSHD_MASKED" | grep -q "/dev/null"; then
        ok "sshd.service is MASKED (-> /dev/null): SSH disabled as required for a hardened image"
    else
        fail "sshd.service is NOT masked (readlink='${SSHD_MASKED}') — hardened images must have SSH disabled and masked (build with SSHD_SERVICE=false)"
    fi
    if [[ -n "$SSHD_WANTS" ]]; then
        fail "sshd is still enabled via: ${SSHD_WANTS}"
    else
        ok "no *.wants/sshd.service or sshd.socket enablement symlinks"
    fi
elif [[ -z "$SSHD_BIN" ]]; then
    warn "sshd NOT installed — SSH into the VM will not work"
elif echo "$SSHD_MASKED" | grep -q "/dev/null"; then
    warn "sshd is MASKED — SSH into the VM will not work (hardened image)"
else
    ok "sshd installed and not masked"
fi

# 5c. Direct root SSH must be refused by sshd itself (pen-test #170). Checked on every image, hardened or not:
#     the vendor-data of IBM Cloud VPC re-enables root key login via cloud-init, so only the sshd drop-in holds.
echo ""
echo "--- [5c] sshd PermitRootLogin no ---"
NOROOT_CONF=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- cat /etc/ssh/sshd_config.d/01-no-root-login.conf 2>/dev/null || true)
if echo "$NOROOT_CONF" | grep -qx 'PermitRootLogin no'; then
    ok "/etc/ssh/sshd_config.d/01-no-root-login.conf has 'PermitRootLogin no'"
else
    fail "no 'PermitRootLogin no' drop-in (/etc/ssh/sshd_config.d/01-no-root-login.conf) — root SSH would be allowed (pen-test #170)"
fi
NOROOT_OVERRIDE=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- sh 'grep -rHiE "^[[:space:]]*PermitRootLogin[[:space:]]+(yes|without-password|prohibit-password|forced-commands-only)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null' 2>/dev/null || true)
if [[ -n "$NOROOT_OVERRIDE" ]]; then
    fail "another file sets PermitRootLogin to a permissive value: ${NOROOT_OVERRIDE}"
fi

# 5d. Nessus /opt instance disk & agent services (idle unless INITDATA nessus=true)
echo ""
echo "--- [5d] Nessus /opt disk and agent services ---"
NESSUS_BIN=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- is-file /usr/local/bin/podvm-nessus-disk 2>/dev/null || echo false)
NESSUS_UNIT=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- is-file /etc/systemd/system/podvm-nessus-disk.service 2>/dev/null || echo false)
NESSUS_WANTS=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- is-symlink /etc/systemd/system/multi-user.target.wants/podvm-nessus-disk.service 2>/dev/null || echo false)

NESSUS_AGT_BIN=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- is-file /usr/local/bin/podvm-nessus-agent 2>/dev/null || echo false)
NESSUS_AGT_UNIT=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- is-file /etc/systemd/system/podvm-nessus-agent.service 2>/dev/null || echo false)
NESSUS_AGT_WANTS=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- is-symlink /etc/systemd/system/multi-user.target.wants/podvm-nessus-agent.service 2>/dev/null || echo false)

if [[ "$NESSUS_BIN" == "true" && "$NESSUS_UNIT" == "true" && "$NESSUS_WANTS" == "true" && \
      "$NESSUS_AGT_BIN" == "true" && "$NESSUS_AGT_UNIT" == "true" && "$NESSUS_AGT_WANTS" == "true" ]]; then
    ok "podvm-nessus-disk & podvm-nessus-agent binaries and services installed and enabled"
else
    warn "Nessus services not fully installed/enabled in image (disk: bin=$NESSUS_BIN unit=$NESSUS_UNIT wants=$NESSUS_WANTS | agent: bin=$NESSUS_AGT_BIN unit=$NESSUS_AGT_UNIT wants=$NESSUS_AGT_WANTS)"
fi

# 5e. Tenable CIS RHEL 10 v1.0.1 fixes (2026-11-19, docs/TENABLE_CIS_AUDIT_FINDINGS_2026-11-19.md). Hardened images only
#     (they carry /etc/podvm-cis-hardened, written by cis-harden.sh). One guestfish call collects every fact.
#     Each check repeats what the Tenable audit reads, so a pass here means "the same file/command output is right".
echo ""
echo "--- [5e] Tenable CIS fixes (hardened images) ---"
CIS_FACTS=$(guestfish --ro -a "$QCOW2" -m "${ROOT_PART}" -- sh '
echo "marker=$(tr "\n" " " < /etc/podvm-cis-hardened 2>/dev/null)"
echo "fstab_tmp=$(grep -Ec "^[^#]+[[:space:]]+/tmp[[:space:]]" /etc/fstab)"
echo "minlen=$(grep -iE "^[[:space:]]*minlen[[:space:]]*=" /etc/security/pwquality.conf | tr -d " ")"
echo "profile_umask=$(grep -lE "^[[:space:]]*umask[[:space:]]+0?27" /etc/profile.d/*.sh 2>/dev/null | tr "\n" " ")"
echo "pass_max=$(grep -E "^PASS_MAX_DAYS[[:space:]]" /etc/login.defs | tr -s " \t" " ")"
echo "root_bin=$(test -d /root/bin && echo y || echo n) root_localbin=$(test -d /root/.local/bin && echo y || echo n)"
echo "usr_local_sbin=$(stat -c %a /usr/local/sbin)"
echo "cron_yearly=$(stat -c "%a %U:%G" /etc/cron.yearly 2>/dev/null || echo missing)"
echo "fw_rules=$(grep -c "destination address=\"[^\"]*\" invert=\"True\"" /etc/firewalld/zones/trusted.xml 2>/dev/null || echo 0)"
echo "nosha1_pmod=$(test -f /etc/crypto-policies/policies/modules/NO-SHA1.pmod && echo y || echo n)"
echo "sha1_left=$(awk -F= "(\$1~/(hash|sign)/ && \$2~/SHA1/ && \$2!~/^[ ]*-[ ]*([^#]+)?SHA1/){print}" /etc/crypto-policies/state/CURRENT.pol 2>/dev/null | wc -l)"
echo "varlog_open=$(find /var/log -type f ! -name "lastlog*" ! -name "wtmp*" ! -name "btmp*" ! -name README -perm /0137 | tr "\n" " ")"
echo "tmpfiles_rhsm=$(test -f /etc/tmpfiles.d/cis-varlog.conf && echo y || echo n)"
echo "rsys_omfwd=$(grep -rhE "action\(type=\"omfwd\"" /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null | wc -l)"
echo "jup_enabled=$(test -L /etc/systemd/system/multi-user.target.wants/systemd-journal-upload.service && echo y || echo n)"
echo "jup_masked=$(readlink /etc/systemd/system/systemd-journal-upload.service 2>/dev/null)"
echo "jsink_enabled=$(test -L /etc/systemd/system/multi-user.target.wants/podvm-journal-sink.service && echo y || echo n)"
echo "pub_services=$(grep -o "service name=\"[a-z0-9-]*\"" /etc/firewalld/zones/public.xml 2>/dev/null | tr "\n" " ")"
echo "systemd_ver=$(rpm -q --qf "%{VERSION}-%{RELEASE}" systemd 2>/dev/null)"
echo "jremote_ver=$(rpm -q --qf "%{VERSION}-%{RELEASE}" systemd-journal-remote 2>/dev/null)"
echo "tmp_unit=$(test -f /etc/systemd/system/tmp.mount && echo y || echo n)"
' 2>/dev/null || true)
cisfact() { echo "$CIS_FACTS" | sed -n "s/^$1=//p" | head -1; }
CIS_MARKER=$(cisfact marker)
if [[ -z "$CIS_MARKER" ]]; then
    ok "not a CIS-hardened image (no /etc/podvm-cis-hardened): Tenable CIS fixes not asserted"
else
    CIS_LEVEL_N=$(echo "$CIS_MARKER" | sed -n 's/^level-\([0-9]\).*/\1/p')
    cischk() { # <label> <condition true?> <detail>
        if [[ "$2" == "1" ]]; then ok "$1"; else fail "$1 -- $3"; fi
    }
    cischk "#13 /etc/cron.yearly exists, 700 root:root" "$([[ $(cisfact cron_yearly) == "700 root:root" ]] && echo 1)" "got '$(cisfact cron_yearly)'"
    cischk "#6 /etc/profile.d/*.sh sets umask 027" "$([[ -n $(cisfact profile_umask) ]] && echo 1)" "no profile.d file with umask 027"
    cischk "#9 /root/bin and /root/.local/bin are directories" "$([[ $(cisfact root_bin) == "y root_localbin=y" ]] && echo 1)" "got '$(cisfact root_bin)'"
    cischk "#9 /usr/local/sbin mode <= 755" "$([[ $(cisfact usr_local_sbin) == "755" || $(cisfact usr_local_sbin) == "750" || $(cisfact usr_local_sbin) == "700" ]] && echo 1)" "got $(cisfact usr_local_sbin)"
    cischk "#3 no /var/log file more open than 0640 (wtmp/btmp/lastlog 0664)" "$([[ -z $(cisfact varlog_open | tr -d ' ') ]] && echo 1)" "open: $(cisfact varlog_open)"
    cischk "#3 tmpfiles.d rule keeps /var/log/rhsm logs 0640 at run time" "$([[ $(cisfact tmpfiles_rhsm) == y ]] && echo 1)" "missing /etc/tmpfiles.d/cis-varlog.conf"
    # #8 (6.2.2.1.1): package present, and the SAME build as systemd (Lesson 94: a skewed pair froze boot)
    cischk "#8 systemd-journal-remote installed, same version-release as systemd" \
        "$([[ -n $(cisfact jremote_ver) && $(cisfact jremote_ver) == $(cisfact systemd_ver) ]] && echo 1)" \
        "systemd='$(cisfact systemd_ver)' journal-remote='$(cisfact jremote_ver)'"
    if [[ "${CIS_LEVEL_N:-0}" -ge 1 && -n $(cisfact jremote_ver) ]]; then
        cischk "#14 systemd-journal-upload enabled (not masked) + loopback sink enabled" \
            "$([[ $(cisfact jup_enabled) == y && -z $(cisfact jup_masked) && $(cisfact jsink_enabled) == y ]] && echo 1)" \
            "upload_wants=$(cisfact jup_enabled) masked='$(cisfact jup_masked)' sink=$(cisfact jsink_enabled)"
        cischk "#5 rsyslog has an omfwd action" "$([[ "$(cisfact rsys_omfwd)" =~ ^[0-9]+$ && "$(cisfact rsys_omfwd)" -ge 1 ]] && echo 1)" "omfwd count '$(cisfact rsys_omfwd)'"
    fi
    if [[ "${CIS_LEVEL_N:-0}" -ge 2 ]]; then
        cischk "#4 pwquality minlen >= 15" "$([[ $(cisfact minlen) =~ ^minlen=(1[5-9]|[2-9][0-9])$ ]] && echo 1)" "got '$(cisfact minlen)'"
        cischk "#7 PASS_MAX_DAYS <= 90" "$([[ $(cisfact pass_max) =~ ^PASS_MAX_DAYS\ ([1-9]|[1-8][0-9]|90)$ ]] && echo 1)" "got '$(cisfact pass_max)'"
        cischk "#15 NO-SHA1.pmod present and no SHA1 left in CURRENT.pol (Tenable awk)" "$([[ $(cisfact nosha1_pmod) == y && $(cisfact sha1_left) == 0 ]] && echo 1)" "pmod=$(cisfact nosha1_pmod) lines_with_sha1=$(cisfact sha1_left)"
    fi
    if [[ "${CIS_LEVEL_N:-0}" -ge 3 ]]; then
        cischk "#1 /etc/fstab has a /tmp line" "$([[ $(cisfact fstab_tmp) -ge 1 ]] && echo 1)" "no /tmp line"
        cischk "#1 real /etc/systemd/system/tmp.mount (keeps is-enabled = enabled)" "$([[ $(cisfact tmp_unit) == y ]] && echo 1)" "missing"
        cischk "#10 firewalld trusted zone has 2 loopback anti-spoof rich rules" "$([[ $(cisfact fw_rules) -ge 2 ]] && echo 1)" "found $(cisfact fw_rules)"
        cischk "4.1.7 public zone has no ssh/cockpit/dhcpv6-client" "$([[ ! $(cisfact pub_services) =~ (ssh|cockpit|dhcpv6-client) ]] && echo 1)" "services: $(cisfact pub_services)"
    fi
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
    payload_img = d.get('payload_image', '?')
    gc_ver = d.get('guest_components_version')
    if not gc_ver or gc_ver == '?':
        if '1.13.' in payload_img: gc_ver = 'v0.21.0+ (RCAR 0.4.0)'
        elif '1.10.' in payload_img: gc_ver = '~v0.12.x (RCAR 0.2.0)'
        else: gc_ver = '?'
    ka_ver = d.get('kata_agent_version')
    if not ka_ver or ka_ver == '?':
        if '1.13.' in payload_img: ka_ver = '3.31.0'
        elif '1.10.' in payload_img: ka_ver = '3.17.0'
        else: ka_ver = '?'
    rows = [
        ('Build date',              d.get('build_date','?')),
        ('RHEL version',            d.get('rhel_version','?')),
        ('Kernel',                  d.get('kernel_version','?')),
        ('Boot mode',               d.get('boot_mode', 'uki')),
        ('UKI filename',            d.get('uki_filename','?')),
        ('Payload image',           payload_img),
        ('Payload digest',          d.get('payload_digest','?')),
        ('Pause bundle image',      d.get('pause_bundle_image','?')),
        ('Guest Components ver',    gc_ver),
        ('Kata Agent ver',          ka_ver),
        ('CDH / AA build date',     d.get('cdh_binary_date', d.get('aa_binary_date', '?'))),
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
# 7. BOOT GATE — actually boot the image in QEMU (secure-boot OVMF + KVM, snapshot=on)
#    Added 2026-11-18 after rhel10-2026111814 / hardened-2026111815 were uploaded to IBM Cloud
#    with every offline gate green but dropped to emergency mode at boot (initramfs had no
#    overlay.ko). Offline file checks cannot prove an image boots. There is NO skip switch:
#    missing qemu/firmware/KVM is a FAIL, never a warning.
#    PASS = reaches a 'login:' prompt with no emergency mode / kernel panic / initrd failure.
#    agent-protocol-forwarder failing is EXPECTED here (no peer-pod user-data) and is ignored.
# ---------------------------------------------------------------------------
echo ""
echo "--- [7] Boot gate: QEMU boot of the image (snapshot, no network) ---"
OVMF_CODE_SB=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd
OVMF_VARS_SRC=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
BOOT_MISSING=""
command -v qemu-system-x86_64 >/dev/null 2>&1 || BOOT_MISSING+=" qemu-system-x86_64"
[[ -r "$OVMF_CODE_SB" ]] || BOOT_MISSING+=" $OVMF_CODE_SB"
[[ -r "$OVMF_VARS_SRC" ]] || BOOT_MISSING+=" $OVMF_VARS_SRC"
[[ -w /dev/kvm ]] || BOOT_MISSING+=" /dev/kvm(writable)"
if [[ -n "$BOOT_MISSING" ]]; then
    fail "Boot gate cannot run, missing:${BOOT_MISSING}. Fix the host; do NOT upload an unbooted image."
else
    BOOT_DIR=$(mktemp -d /tmp/verify-boot-XXXXXX)
    BOOT_LOG="$BOOT_DIR/serial.log"; : > "$BOOT_LOG"
    cp "$OVMF_VARS_SRC" "$BOOT_DIR/vars.fd"
    timeout 240 qemu-system-x86_64 -machine q35,smm=on,accel=kvm -cpu host -m 3072 -smp 2 \
        -global driver=cfi.pflash01,property=secure,value=on \
        -drive if=pflash,format=raw,unit=0,file="$OVMF_CODE_SB",readonly=on \
        -drive if=pflash,format=raw,unit=1,file="$BOOT_DIR/vars.fd" \
        -drive file="$QCOW2",if=virtio,format=qcow2,snapshot=on \
        -nic none -display none -no-reboot -monitor none -serial file:"$BOOT_LOG" \
        > "$BOOT_DIR/qemu.log" 2>&1 &
    QPID=$!
    BOOT_RESULT="timeout"
    for _ in $(seq 1 120); do
        sleep 2
        if grep -a -qE 'Entering emergency mode|Reached target .*Emergency|end Kernel panic|Kernel panic - not syncing|dracut-emergency|Failed to start systemd-volatile-root|Dependency failed for initrd-root-fs' "$BOOT_LOG"; then
            BOOT_RESULT="bad"; break
        fi
        if grep -a -qE '^[A-Za-z0-9._-]+ login: ' "$BOOT_LOG"; then
            BOOT_RESULT="login"; break
        fi
        kill -0 "$QPID" 2>/dev/null || { BOOT_RESULT="qemu-exited"; break; }
    done
    kill "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
    case "$BOOT_RESULT" in
        login) ok "Image boots to a login prompt in QEMU (no emergency mode, no panic)" ;;
        bad)   fail "Image BOOT FAILED in QEMU: $(grep -a -E 'emergency mode|Kernel panic|volatile-root|Dependency failed' "$BOOT_LOG" | head -3 | tr '\n' '|' | cut -c1-300) — serial log kept: $BOOT_LOG"; BOOT_KEEP=1 ;;
        *)     fail "Image did not reach a login prompt in QEMU (result: $BOOT_RESULT) — serial log kept: $BOOT_LOG"; BOOT_KEEP=1 ;;
    esac
    [[ "${BOOT_KEEP:-0}" == "1" ]] || rm -rf "$BOOT_DIR"
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
