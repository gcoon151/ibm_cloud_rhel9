#!/bin/bash
# =============================================================================
# cis-scan.sh — boot a finished RHEL 10 podvm QCOW2 locally (qemu/OVMF) and run the
# OpenSCAP CIS Level 1 Server scan inside it. Runs ON THE BUILD HOST.
#
# The QCOW2 is never modified: the guest boots from a throw-away qcow2 backing-file overlay.
# Nothing the scan installs (openscap, scap-security-guide) or registers survives.
#
# Usage:   bash rhel10-experimental/scripts/cis-scan.sh /path/to/image.qcow2 [profile]
# Needs:   .env at repo root with ORG_ID + ACTIVATION_KEY (RHSM; read via stdin, never logged)
# Output:  cis_results/<image-name>/{results.xml,report.html,oscap.out,failures.tsv,summary.txt}
# Time:    ~10 min (boot ~1 min, dnf install ~2 min, oscap ~3-5 min)
#
# Why the /etc/rhsm copy step: the kickstarts mount an empty tmpfs on /etc/rhsm (needed so IBM Cloud
# instantiation can register on boot); it hides the package's files. Lesson 81 workaround copies them in.
# =============================================================================
set -euo pipefail

IMG="${1:?usage: cis-scan.sh <image.qcow2> [profile]}"
PROFILE="${2:-xccdf_org.ssgproject.content_profile_cis_server_l1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAME="$(basename "${IMG%.qcow2}")"
OUT="${CIS_OUT_DIR:-${REPO_ROOT}/cis_results}/${NAME}"
PORT="${CIS_SSH_PORT:-2225}"
WORK="$(mktemp -d /tmp/cis-scan-XXXXXX)"
KEY="${CIS_SSH_KEY:-$HOME/.ssh/id_ed25519}"
QPID=""

[[ -f "$IMG" ]] || { echo "ERROR: image not found: $IMG" >&2; exit 1; }
[[ -f "$KEY" && -f "$KEY.pub" ]] || { echo "ERROR: ssh key $KEY(.pub) missing" >&2; exit 1; }
[[ -f "${REPO_ROOT}/.env" ]] || { echo "ERROR: ${REPO_ROOT}/.env missing" >&2; exit 1; }
set -a; source "${REPO_ROOT}/.env"; set +a
[[ -n "${ORG_ID:-}" && -n "${ACTIVATION_KEY:-}" ]] || { echo "ERROR: ORG_ID/ACTIVATION_KEY not in .env" >&2; exit 1; }
mkdir -p "$OUT"

SSH_OPTS=(-i "$KEY" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o IdentitiesOnly=yes)
SSH_USER=""
rsh() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@127.0.0.1" "$@"; }

cleanup() {
    if [[ -n "$SSH_USER" ]]; then
        rsh 'sudo subscription-manager unregister >/dev/null 2>&1 || true' 2>/dev/null || true
    fi
    [[ -n "$QPID" ]] && kill "$QPID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "--- 1. overlay + cloud-init seed ---"
qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$IMG")" "$WORK/overlay.qcow2"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars.fd"
cat > "$WORK/user-data" <<EOF
#cloud-config
disable_root: false
ssh_pwauth: false
ssh_authorized_keys:
  - $(cat "$KEY.pub")
EOF
printf 'instance-id: cis-scan\nlocal-hostname: cis-scan\n' > "$WORK/meta-data"
cloud-localds "$WORK/seed.iso" "$WORK/user-data" "$WORK/meta-data"

echo "--- 2. boot ---"
qemu-system-x86_64 -enable-kvm -cpu host -machine q35 -m 8192 -smp 4 -display none \
    -serial "file:$WORK/console.log" -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -drive file="$WORK/overlay.qcow2",if=virtio,format=qcow2 \
    -drive file="$WORK/seed.iso",if=virtio,format=raw \
    -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${PORT}-:22 -device virtio-net-pci,netdev=net0 &
QPID=$!

echo "--- 3. wait for ssh (max 240s) ---"
for i in $(seq 1 48); do
    for u in root vpcuser; do
        if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$u@127.0.0.1" true 2>/dev/null; then SSH_USER="$u"; break 2; fi
    done
    kill -0 "$QPID" 2>/dev/null || { echo "ERROR: qemu exited early" >&2; grep -a -iE "panic|verity" "$WORK/console.log" | head -3 >&2; exit 1; }
    sleep 5
done
[[ -n "$SSH_USER" ]] || { echo "ERROR: no ssh within 240s (cloud-init seed not honoured?). Console tail:" >&2; tail -c 600 "$WORK/console.log" >&2; exit 1; }
echo "  ssh up as $SSH_USER"
SUDO=""; [[ "$SSH_USER" != "root" ]] && SUDO="sudo"

echo "--- 4. rhsm workaround + register + install openscap + scan (remote) ---"
# Script and creds go over stdin only (not visible in ps, not written to disk on either side).
{
    printf 'ORG_ID=%q\nACTIVATION_KEY=%q\nPROFILE=%q\n' "$ORG_ID" "$ACTIVATION_KEY" "$PROFILE"
    cat <<'REMOTE'
set -u
mkdir -p /mnt/rootview && mount --bind / /mnt/rootview
cp -a /mnt/rootview/etc/rhsm/{ca,facts,pluginconf.d,rhsm.conf} /etc/rhsm/
umount /mnt/rootview
[ -s /etc/rhsm/ca/redhat-uep.pem ] || { echo "ERROR: rhsm ca copy failed"; exit 11; }
subscription-manager register --org="$ORG_ID" --activationkey="$ACTIVATION_KEY" --force 2>&1 | sed -E 's/(activationkey=)[^ ]+/\1***/' | tail -2
subscription-manager status | grep -q 'Overall Status: Registered' || { echo "ERROR: not registered"; exit 12; }
dnf install -y openscap-scanner scap-security-guide >/root/dnf.out 2>&1 || { tail -5 /root/dnf.out; echo "ERROR: dnf install failed"; exit 13; }
DS=/usr/share/xml/scap/ssg/content/ssg-rhel10-ds.xml
[ -f "$DS" ] || { echo "ERROR: $DS missing"; exit 14; }
oscap xccdf eval --profile "$PROFILE" --results /root/results.xml --report /root/report.html "$DS" >/root/oscap.out 2>&1
rc=$?   # 0 = all pass, 2 = some fail, anything else = scan error
[ "$rc" = 0 ] || [ "$rc" = 2 ] || { tail -5 /root/oscap.out; echo "ERROR: oscap rc=$rc"; exit 15; }
echo "OSCAP_RC=$rc"
REMOTE
} | rsh "$SUDO bash -s"

echo "--- 5. fetch results ---"
for f in results.xml report.html oscap.out; do
    rsh "$SUDO cat /root/$f" > "$OUT/$f"
    [[ -s "$OUT/$f" ]] || { echo "ERROR: $f empty" >&2; exit 16; }
done

echo "--- 6. summarise ---"
python3 - "$OUT" <<'PY'
import sys, xml.etree.ElementTree as ET, collections
out = sys.argv[1]
root = ET.parse(out + "/results.xml").getroot()
ns = {"x": root.tag.split("}")[0].strip("{")}
counts = collections.Counter(); fails = []
for rr in root.iter("{%s}rule-result" % ns["x"]):
    res = rr.findtext("x:result", namespaces=ns)
    counts[res] += 1
    if res == "fail":
        fails.append((rr.get("idref").replace("xccdf_org.ssgproject.content_rule_", ""), rr.get("severity", "")))
with open(out + "/failures.tsv", "w") as f:
    f.write("rule_id\tseverity\n")
    for rid, sev in sorted(fails): f.write(f"{rid}\t{sev}\n")
line = f"pass={counts['pass']} fail={counts['fail']} notapplicable={counts['notapplicable']} error={counts['error']} notchecked={counts['notchecked']} unknown={counts['unknown']}"
open(out + "/summary.txt", "w").write(line + "\n")
print(line)
PY
echo "✓ results in $OUT"
