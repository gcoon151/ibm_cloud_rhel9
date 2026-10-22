#!/bin/bash
# =============================================================================
# cis-dev-loop.sh — DEV-ONLY fast loop for cis-harden.sh changes. Runs ON THE BUILD HOST.
#   Stage 1: qcow2 overlay of a finished image + `virt-customize --run cis-harden.sh` (same call the build makes)
#   Stage 2: DEV-ONLY verity bypass (BLS options -> root=PARTUUID=<verity data partition>), then cis-scan.sh
# The overlay is NOT a releasable image (verity hash no longer matches; boot entry rewritten) and is deleted on exit.
# Real verification = full build (build-rhel10-overlay.sh HARDENED=1) + cis-scan.sh, then IBM Cloud.
#
# Usage: bash rhel10-experimental/scripts/cis-dev-loop.sh [base.qcow2]    (default: newest rhel10-hardened-*.qcow2)
# Output: cis_results/cis-dev-overlay/{summary.txt,failures.tsv,...}; harden log /tmp/cis-dev-harden.log
# Time:   stage 1 ~1 min, stage 2 ~5 min
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR=/var/lib/libvirt/images/rhel10          # libvirt ACL lives here (virt-customize needs it)
BASE="${1:-$(ls -t ${DIR}/rhel10-hardened-*.qcow2 | head -1)}"
DEV="${DIR}/cis-dev-overlay.qcow2"
[[ -f "$BASE" ]] || { echo "ERROR: base not found: $BASE" >&2; exit 1; }

rm -f "$DEV"
qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DEV"
trap 'rm -f "$DEV"' EXIT

echo "--- stage 1: virt-customize --run cis-harden.sh + dev verity bypass ---"
virt-customize --memsize 4096 -a "$DEV" \
    --run "${REPO_ROOT}/scripts/coco/podvm/cis-harden.sh" \
    --run-command "sed -i -E 's#^options .*verity_root_data=PARTUUID=([0-9a-f-]+).*#options ro console=ttyS0 root=PARTUUID=\1 systemd.volatile=overlay#' /boot/loader/entries/*.conf; grep -h '^options' /boot/loader/entries/*.conf" \
    > /tmp/cis-dev-harden.log 2>&1 || { tail -15 /tmp/cis-dev-harden.log; echo "ERROR: stage 1 failed" >&2; exit 1; }
grep -a "cis-harden.sh complete" /tmp/cis-dev-harden.log | cut -c1-200 || { echo "ERROR: cis-harden.sh did not complete" >&2; exit 1; }
grep -aq "root=PARTUUID=" /tmp/cis-dev-harden.log || { echo "ERROR: verity bypass sed did not apply" >&2; exit 1; }

echo "--- stage 2: boot + scan ---"
bash "${REPO_ROOT}/rhel10-experimental/scripts/cis-scan.sh" "$DEV"
