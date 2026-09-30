#!/bin/bash
# =============================================================================
# rebuild-base-rhel10.sh  —  Layer 1 of 3: Build RHEL 10 base QCOW2 from ISO
#
# Upstream reference: coco-podvm-scripts/helpers/rhel10-dm-root.ks
# Deviations: see rhel10-experimental/UPSTREAM_DEVIATIONS.md
#
# Produces a date-stamped, read-only base QCOW2:
#   /tmp/rhel10-ks-base-YYYYMMDD.qcow2
#
# Why /tmp and not ~/.local/share/libvirt/images/:
#   virt-install uses qemu:///system (needed for KVM access — gcoon is in
#   libvirt group but not kvm group). The system QEMU daemon runs as uid 64055
#   (libvirt-qemu) which cannot access /home/gcoon. /tmp is world-accessible.
#   This matches all prior successful builds. See UPSTREAM_DEVIATIONS.md.
#
# This file is NEVER modified after creation. The overlay script (Layer 3)
# copies it to a dated output path and modifies the copy. Do not pass a base
# file to the overlay script — only pass copies.
#
# Usage:
#   bash helpers/rebuild-base-rhel10.sh
#   bash helpers/rebuild-base-rhel10.sh --iso /path/to/rhel-10.2-x86_64-dvd.iso
#
# The script exits non-zero and does nothing if a base for today already exists.
# To force a rebuild on the same day, remove the existing dated file first.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Output goes to /tmp so qemu:///system (uid libvirt-qemu) can access it.
IMAGE_DIR="/tmp"
# Allow overriding the kickstart file for baseline runs (B-0 uses upstream verbatim).
KS_FILE="${KS_OVERRIDE:-${SCRIPT_DIR}/rhel10-dm-root.ks}"
DATE=$(date -u +%Y%m%d)
OUTPUT_IMAGE="${IMAGE_DIR}/rhel10-ks-base-${DATE}.qcow2"
VM_NAME="rhel10-ks-build-${DATE}"

# Default ISO location — override with --iso flag
ISO_PATH="${HOME}/rhel-10.2-x86_64-dvd.iso"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso) ISO_PATH="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

echo "================================================================="
echo "RHEL 10 base QCOW2 rebuild  —  Layer 1 of 3"
echo "  ISO:         ${ISO_PATH}"
echo "  Kickstart:   ${KS_FILE}"
echo "  Output:      ${OUTPUT_IMAGE}"
echo "  Build start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================="

# --- Pre-flight checks ------------------------------------------------------

if [[ ! -f "${ISO_PATH}" ]]; then
    echo "ERROR: ISO not found: ${ISO_PATH}" >&2
    echo "       Download from https://access.redhat.com/downloads" >&2
    exit 1
fi

if [[ ! -f "${KS_FILE}" ]]; then
    echo "ERROR: Kickstart not found: ${KS_FILE}" >&2
    exit 1
fi

if [[ -f "${OUTPUT_IMAGE}" ]]; then
    echo "ERROR: Output file already exists: ${OUTPUT_IMAGE}" >&2
    echo "       A base QCOW2 for today already exists. This is intentional —" >&2
    echo "       bases are immutable. To rebuild, delete or rename the existing" >&2
    echo "       file first, then re-run." >&2
    echo "       If you want to reuse today's base for an overlay build, run:" >&2
    echo "         bash rhel10-experimental/scripts/build-rhel10-overlay.sh ${OUTPUT_IMAGE}" >&2
    exit 1
fi

mkdir -p "${IMAGE_DIR}"

# Use qemu:///system for KVM access (gcoon is in libvirt but not kvm group).
# Output is in /tmp which is world-accessible to the libvirt-qemu uid.
export LIBVIRT_DEFAULT_URI="qemu:///system"

# Clean up any leftover VM with the same name from a previous failed run
virsh destroy "${VM_NAME}" 2>/dev/null || true
virsh undefine "${VM_NAME}" 2>/dev/null || true

# --- Step 1: Run virt-install -----------------------------------------------
echo ""
echo "--- Step 1: virt-install (ISO + kickstart) ---"
echo "This takes 15-25 minutes. The VM will power off when done."
echo ""

virt-install \
    --connect qemu:///system \
    --virt-type kvm \
    --os-variant rhel10.0 \
    --arch x86_64 \
    --boot uefi \
    --name "${VM_NAME}" \
    --memory 8192 \
    --location "${ISO_PATH}" \
    --disk "path=${OUTPUT_IMAGE},format=qcow2,bus=scsi,size=7" \
    --initrd-inject="${KS_FILE}" \
    --nographics \
    --noautoconsole \
    --extra-args "console=ttyS0 inst.ks=file:/rhel10-dm-root.ks" \
    --transient 2>&1 | tee /tmp/rhel10-virt-install.log

echo ""
echo "--- Step 1: Waiting for install to finish ---"

# Capture serial console output to a log file for post-mortem diagnosis.
# The PTY appears a few seconds after domain start.
CONSOLE_LOG="/tmp/rhel10-anaconda-console-${DATE}.log"
(
    sleep 3
    PTY=$(sudo virsh --connect qemu:///system qemu-monitor-command "${VM_NAME}" \
        --hmp 'info chardev' 2>/dev/null | grep charserial0 | grep -o '/dev/pts/[0-9]*')
    if [[ -n "${PTY}" ]]; then
        echo "Console PTY: ${PTY} — logging to ${CONSOLE_LOG}"
        sudo timeout 2000 cat "${PTY}" > "${CONSOLE_LOG}" 2>/dev/null &
    else
        echo "WARNING: Could not find serial console PTY — no console log will be captured"
    fi
) &
CONSOLE_CAPTURE_PID=$!
echo "Console capture started (log: ${CONSOLE_LOG})"

START_WAIT=$(date +%s)
MAX_WAIT=1800  # 30 min hard limit
while virsh --connect qemu:///system list 2>/dev/null | grep -q "${VM_NAME}"; do
    ELAPSED=$(( $(date +%s) - START_WAIT ))
    if [[ ${ELAPSED} -ge ${MAX_WAIT} ]]; then
        echo "ERROR: Install timed out after ${MAX_WAIT}s" >&2
        virsh --connect qemu:///system destroy "${VM_NAME}" 2>/dev/null || true
        sudo rm -f "${OUTPUT_IMAGE}"
        exit 1
    fi
    [[ $(( ELAPSED % 60 )) -eq 0 ]] && echo "  ...${ELAPSED}s elapsed"
    sleep 10
done
ELAPSED_FINAL=$(( $(date +%s) - START_WAIT ))
kill ${CONSOLE_CAPTURE_PID} 2>/dev/null || true
echo "✓ Install finished (${ELAPSED_FINAL}s)"
echo "  Console log: ${CONSOLE_LOG} ($(wc -l < "${CONSOLE_LOG}" 2>/dev/null || echo 0) lines)"

# --- Step 2: Basic sanity checks on the produced image ----------------------
echo ""
echo "--- Step 2: Image sanity checks ---"

# The QCOW2 is owned by root (written by qemu:///system). Fix ownership.
sudo chown "$(id -u):$(id -g)" "${OUTPUT_IMAGE}"
chmod 644 "${OUTPUT_IMAGE}"

if [[ ! -f "${OUTPUT_IMAGE}" ]]; then
    echo "ERROR: virt-install completed but output file not found: ${OUTPUT_IMAGE}" >&2
    exit 1
fi

VIRT_SIZE=$(qemu-img info --output json "${OUTPUT_IMAGE}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['virtual-size'])")
VIRT_GIB=$(( VIRT_SIZE / 1024 / 1024 / 1024 ))
DISK_SIZE=$(du -h "${OUTPUT_IMAGE}" | cut -f1)
echo "  Virtual size: ${VIRT_GIB} GiB  (on-disk compressed: ${DISK_SIZE})"

if [[ ${VIRT_GIB} -lt 5 ]]; then
    echo "ERROR: Image is only ${VIRT_GIB} GiB virtual — install likely failed." >&2
    echo "       Expected >= 7 GiB. Removing corrupt output." >&2
    sudo rm -f "${OUTPUT_IMAGE}"
    exit 1
fi
echo "✓ Virtual size OK (${VIRT_GIB} GiB)"

# --- Step 3: Check partition GUIDs ------------------------------------------
echo ""
echo "--- Step 3: Partition GUID check ---"

# sfdisk -d on a raw image outputs full device paths, e.g.:
#   /tmp/foo.raw1 : ... type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B ...
# Match on 'raw1'/'raw2' (suffix of the temp filename) not 'part1'/'part2'.
RAW_TMP=$(sudo mktemp /tmp/rhel10-chk-XXXXXX.raw)
sudo qemu-img convert -f qcow2 -O raw "${OUTPUT_IMAGE}" "${RAW_TMP}"
SFDISK_OUT=$(sudo sfdisk -d "${RAW_TMP}" 2>/dev/null)
sudo rm -f "${RAW_TMP}"
echo "${SFDISK_OUT}"

EFI_GUID=$(echo "${SFDISK_OUT}"  | grep 'raw1 ' | grep -oi 'type=[0-9A-Fa-f-]*' | cut -d= -f2 || true)
ROOT_GUID=$(echo "${SFDISK_OUT}" | grep 'raw2 ' | grep -oi 'type=[0-9A-Fa-f-]*' | cut -d= -f2 || true)

echo "  EFI  partition GUID: ${EFI_GUID}"
echo "  Root partition GUID: ${ROOT_GUID}"

GUID_OK=true
if ! echo "${EFI_GUID}" | grep -qi "C12A7328"; then
    echo "ERROR: EFI partition GUID wrong. Expected C12A7328-F81F-11D2-BA4B-00A0C93EC93B" >&2
    GUID_OK=false
fi
if ! echo "${ROOT_GUID}" | grep -qi "4F68BCE3"; then
    echo "ERROR: Root partition GUID wrong. Expected 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709" >&2
    GUID_OK=false
fi
if [[ "${GUID_OK}" = false ]]; then
    echo "GUID check failed. Image left at ${OUTPUT_IMAGE} for inspection." >&2
    echo "Run: sudo sfdisk -d <(sudo qemu-img convert -f qcow2 -O raw ${OUTPUT_IMAGE} /dev/stdout)" >&2
    echo "Then fix the kickstart and rebuild." >&2
    exit 1
fi
echo "✓ Partition GUIDs correct"

# --- Step 4: Confirm UKI is in EFI partition --------------------------------
echo ""
echo "--- Step 4: EFI partition contents ---"

EFI_CONTENTS=$(guestfish --ro -a "${OUTPUT_IMAGE}" -m /dev/sda1 \
    ls /EFI/Linux/ 2>/dev/null | grep -v 'libguestfs:' || true)

echo "  /EFI/Linux/ contents:"
echo "${EFI_CONTENTS}" | sed 's/^/    /'

EFI_COUNT=$(echo "${EFI_CONTENTS}" | grep -c '\.efi$' || true)
if [[ ${EFI_COUNT} -eq 0 ]]; then
    echo "ERROR: No .efi file in /EFI/Linux/ — UKI was not placed by kickstart." >&2
    echo "       Check that kernel-uki-virt is in %packages and kernel-install ran." >&2
    rm -f "${OUTPUT_IMAGE}"
    exit 1
fi
if [[ ${EFI_COUNT} -gt 1 ]]; then
    echo "WARNING: ${EFI_COUNT} .efi files found — expected exactly 1." >&2
    echo "         This may be harmless but review the kickstart." >&2
fi

KERNEL_VER=$(echo "${EFI_CONTENTS}" | grep '\.efi$' | grep -oP '\d+\.\d+\.\d+-\d+\.\d+\.\d+\.[^.]+' | head -1 || true)
echo "✓ UKI present: kernel ${KERNEL_VER}"

# --- Step 5: Mark read-only and record --------------------------------------
echo ""
echo "--- Step 5: Mark base read-only ---"

chmod 444 "${OUTPUT_IMAGE}"
echo "✓ Permissions set to 444 (read-only)"

SHA256=$(sha256sum "${OUTPUT_IMAGE}" | awk '{print $1}')
echo ""
echo "================================================================="
echo "BASE IMAGE READY"
echo "  Output:       ${OUTPUT_IMAGE}"
echo "  Kernel:       ${KERNEL_VER}"
echo "  SHA256:       ${SHA256}"
echo "  Permissions:  $(stat -c %a ${OUTPUT_IMAGE}) (read-only)"
echo "  Built:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================================="
echo ""
echo "Next step — run the overlay build against this base:"
echo "  bash rhel10-experimental/scripts/build-rhel10-overlay.sh ${OUTPUT_IMAGE}"
