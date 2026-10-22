#!/bin/bash
# =============================================================================
# cis-dev-loop.sh — DEV-ONLY fast loop for cis-harden.sh changes. Runs ON THE BUILD HOST.
#   Stage 1: qcow2 overlay of a finished image + `virt-customize --run cis-harden.sh` (same call the build makes)
#   Stage 2: DEV-ONLY verity bypass (BLS options -> root=PARTUUID=<verity data partition>), then cis-scan.sh
# The overlay is NOT a releasable image (verity hash no longer matches; boot entry rewritten) and is deleted on exit.
# Real verification = full build (build-rhel10-overlay.sh HARDENED=1) + cis-scan.sh, then IBM Cloud.
#
# Usage: CIS_LEVEL=1..4 bash rhel10-experimental/scripts/cis-dev-loop.sh [base.qcow2]   (tiers cumulative; see cis-harden.sh)    (default: newest rhel10-hardened-*.qcow2)
# Output: cis_results/cis-dev-<tag>/{summary.txt,failures.tsv,...}; harden log $HLOG
# Parallel: run several at once with different CIS_LEVEL / CIS_TAG (each gets its own overlay, logs, port, results dir).
# Time:   stage 1 ~1 min, stage 2 ~5 min
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR=/var/lib/libvirt/images/rhel10          # libvirt ACL lives here (virt-customize needs it)
BASE="${1:-$(ls -t ${DIR}/rhel10-hardened-*.qcow2 | head -1)}"
TAG="${CIS_TAG:-tier${CIS_LEVEL:-1}}"       # unique per concurrent run (overlay, logs, results dir, ssh port all derive from it)
DEV="${DIR}/cis-dev-${TAG}.qcow2"
HLOG="/tmp/cis-dev-harden-${TAG}.log"; MARK="/tmp/cis-dev-marker-${TAG}.txt"
[[ -f "$BASE" ]] || { echo "ERROR: base not found: $BASE" >&2; exit 1; }

[[ -f "${REPO_ROOT}/.env" ]] && { set -a; source "${REPO_ROOT}/.env"; set +a; }
[[ -n "${ORG_ID:-}" && -n "${ACTIVATION_KEY:-}" ]] || { echo "ERROR: ORG_ID/ACTIVATION_KEY needed (cis-harden.sh tiers use dnf)" >&2; exit 1; }
rm -f "$DEV"
qemu-img create -q -f qcow2 -F qcow2 -b "$BASE" "$DEV"
trap 'rm -f "$DEV" "$MARK"' EXIT

echo "--- stage 1: virt-customize --run cis-harden.sh + dev verity bypass ---"
# --no-selinux-relabel is REQUIRED here: otherwise virt-customize drops /.autorelabel, and the dev boot (root mounted ro) can never
# clear it => endless reboot loop. (Unlabeled new files are fine for a config scan; the real build relabels.) Lesson 94/95.
# Lesson 96: selinux-autorelabel-mark.service runs at first boot (ConditionSecurity=!selinux passes in libguestfs context),
# touches /.autorelabel, then selinux-autorelabel.service runs on the actual qemu boot and reboots the VM. cis-scan.sh uses
# -no-reboot so qemu exits on that reboot and the scan never runs. Fix: mask both services in the dev overlay only.
# register first, exactly as coco-components.sh does (SM_REGISTER); always unregister afterwards, even if harden fails
rc=0
virt-customize --memsize 4096 --no-selinux-relabel -a "$DEV" \
    --run-command "subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY} >/dev/null" \
    --run-command "echo ${CIS_LEVEL:-1} > /tmp/cis-level" \
    --run "${REPO_ROOT}/scripts/coco/podvm/cis-harden.sh" \
    --run-command "systemctl mask selinux-autorelabel.service selinux-autorelabel-mark.service" \
    --run-command "restorecon -R /etc /usr/lib /var/lib 2>/dev/null || true" \
    --run-command "sed -i -E 's#^options .*verity_root_data=PARTUUID=([0-9a-f-]+).*#options ro console=ttyS0 root=PARTUUID=\1 systemd.volatile=overlay enforcing=0#' /boot/loader/entries/*.conf; grep -h '^options' /boot/loader/entries/*.conf" \
    > $HLOG 2>&1 || rc=$?
virt-customize --memsize 4096 --no-selinux-relabel -a "$DEV" --run-command "subscription-manager unregister >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
[[ $rc -eq 0 ]] || { grep -avE '^\[ *[0-9.]+\] (Setting|Finishing|SELinux|Running: sub)' $HLOG | tail -12 | sed -E 's/activationkey=[^ ]+/activationkey=***/'; echo "ERROR: stage 1 failed (rc=$rc)" >&2; exit 1; }
# virt-customize does not echo --run output; assert via guestfish on the overlay (AGENTS.md: assert artifacts)
guestfish --ro -a "$DEV" -i cat /etc/podvm-cis-hardened > $MARK 2>/dev/null \
    || { echo "ERROR: /etc/podvm-cis-hardened missing - cis-harden.sh did not complete" >&2; exit 1; }
echo "  cis-harden.sh steps: $(tr '\n' ' ' < $MARK)"
guestfish --ro -a "$DEV" -i sh 'cat /boot/loader/entries/*.conf' 2>/dev/null | grep -q 'root=PARTUUID=' \
    || { echo "ERROR: verity bypass sed did not apply" >&2; exit 1; }

echo "--- stage 2: boot + scan ---"
bash "${REPO_ROOT}/rhel10-experimental/scripts/cis-scan.sh" "$DEV"
