#! /bin/bash
# IBM MOD: set -e so that get-artifacts.sh failure kills the build loudly.
# Without this, a podman pull failure exits get-artifacts.sh nonzero, but
# coco-components.sh continues to virt-customize --copy-in podvm-binaries.tar.gz
# (source does not exist), which also exits nonzero — but is silently swallowed.
# virt-customize then exits 0 and build-rhel10-overlay.sh runs verity on a QCOW2
# with no kata-agent or agent-protocol-forwarder. Symptom: port 15150 failures.
set -e

INPUT_IMAGE=$1

SCRIPT_FOLDER=${SCRIPT_FOLDER:-$(dirname $0)}
SCRIPT_FOLDER=$(realpath $SCRIPT_FOLDER)

PODVM_BINARY_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:5ddecbd46f55aec869ef0007a75c2fd661c06c9b1fa68da9177f69be065ec689
PODVM_BINARY_LOCATION_DEF=/podvm-binaries.tar.gz
PAUSE_BUNDLE_DEF=quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload@sha256:15d70ba45e3263be545254060674e93fbdef3922480f9c3c80381c599ca1cb67
PAUSE_BUNDLE_LOCATION_DEF=/pause-bundle.tar.gz

function local_help()
{
    echo "Usage: $0 <INPUT_IMAGE>"
    echo "Usage: $0 help"
    echo ""
    echo "The purpose of this script is to extract and install all CoCo guest"
    echo "components into a given disk"
    echo ""
    echo "Options (define them as variable):"
    echo "ARTIFACTS_FOLDER:      optional  - where the podvm binaries and pause bundle are. Default $SCRIPT_FOLDER/coco/podvm"
    echo "PODVM_BINARY:          optional - registry containing podvm binary. Default:$PODVM_BINARY_DEF "
    echo "PODVM_BINARY_LOCATION: optional - location in container containing podvm binary. Default: $PODVM_BINARY_LOCATION_DEF"
    echo "PAUSE_BUNDLE:          optional - registry containing pause bundle. Default: $PAUSE_BUNDLE_DEF"
    echo "PAUSE_BUNDLE_LOCATION: optional - location in container containing pause bundle. Default: $PAUSE_BUNDLE_LOCATION_DEF"
    echo "ROOT_PASSWORD:         optional - set root's password. Default: disabled"
}

PODVM_BINARY=${PODVM_BINARY:-"$PODVM_BINARY_DEF"}
PODVM_BINARY_LOCATION=${PODVM_BINARY_LOCATION:-"$PODVM_BINARY_LOCATION_DEF"}

PAUSE_BUNDLE=${PAUSE_BUNDLE:-"$PAUSE_BUNDLE_DEF"}
PAUSE_BUNDLE_LOCATION=${PAUSE_BUNDLE_LOCATION:-"$PAUSE_BUNDLE_LOCATION_DEF"}

ARTIFACTS_FOLDER=${ARTIFACTS_FOLDER:-"$SCRIPT_FOLDER/coco/podvm"}

if [ -z ${INPUT_IMAGE} ]; then
    local_help
    exit 1
fi

if [[ $INPUT_IMAGE == "help" ]]; then
    local_help
    exit 0
fi

function print_params()
{
    echo ""
    echo "INPUT_IMAGE: $INPUT_IMAGE"
    echo "SCRIPT_FOLDER: $SCRIPT_FOLDER"
    echo "ARTIFACTS_FOLDER: $ARTIFACTS_FOLDER"
    echo "PODVM_BINARY: $PODVM_BINARY"
    echo "PODVM_BINARY_LOCATION: $PODVM_BINARY_LOCATION"
    echo "PAUSE_BUNDLE: $PAUSE_BUNDLE"
    echo "PAUSE_BUNDLE_LOCATION: $PAUSE_BUNDLE_LOCATION"
    echo "ROOT_PASSWORD: $ROOT_PASSWORD"
    echo ""
}

INPUT_IMAGE=$(realpath "$INPUT_IMAGE")

print_params
echo ""

export PODVM_BINARY
export PODVM_BINARY_LOCATION
export PAUSE_BUNDLE
export PAUSE_BUNDLE_LOCATION
export DEST_PATH=$ARTIFACTS_FOLDER
$ARTIFACTS_FOLDER/get-artifacts.sh

# create luks-config.tar.gz
"$ARTIFACTS_FOLDER/luks-scratch/build.sh"

echo ""
ls $ARTIFACTS_FOLDER

echo ""
EXTRA_ARGS=""
SM_REGISTER=""
[[ -n "$ROOT_PASSWORD" ]] && EXTRA_ARGS=" --root-password password:${ROOT_PASSWORD} "
[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && SM_REGISTER=(--run-command "subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY}") || SM_REGISTER=()

# IBM MOD: Uptycs EDR is mandatory for IBM images. build-rhel10-overlay.sh stages these
# four files into ARTIFACTS_FOLDER; fail loudly if any is missing (no silent skip).
for f in uptycs-complete.tar.gz provision-uptycs.sh uptycs-osquery.service install-uptycs.sh; do
    if [[ ! -s "$ARTIFACTS_FOLDER/$f" ]]; then
        echo "ERROR: $ARTIFACTS_FOLDER/$f missing — Uptycs cannot be installed" >&2
        exit 1
    fi
done

# IBM MOD: HARDENED=1 -> CIS safe-tier hardening (scripts/coco/podvm/cis-harden.sh), run before verity.
HARDEN_ARGS=()
if [[ -n "${HARDENED:-}" && "${HARDENED}" != "0" ]]; then
    [[ "${HARDENED}" =~ ^[1-4]$ ]] || { echo "ERROR: HARDENED must be 1-4 (CIS tier), got '${HARDENED}'" >&2; exit 1; }
    [[ -s "$ARTIFACTS_FOLDER/cis-harden.sh" ]] || { echo "ERROR: HARDENED=1 but $ARTIFACTS_FOLDER/cis-harden.sh missing" >&2; exit 1; }
    HARDEN_ARGS=(--run-command "echo ${HARDENED} > /tmp/cis-level" --run "$ARTIFACTS_FOLDER/cis-harden.sh")
fi

# IBM MOD (2026-11-18): the dnf kernel update runs kernel-install -> dracut inside the virt-customize
# appliance, which builds a HOST-ONLY initramfs (ext4 only, no overlay.ko). The image boots with
# systemd.volatile=overlay, so systemd-volatile-root then fails in the initrd -> emergency mode
# (proven on rhel10-2026111814: new initramfs had no kernel/fs/overlayfs). Write the dracut config
# BEFORE dnf so the new kernel's initramfs is generic + has overlay, then regenerate explicitly.
DRACUT_CONF="printf 'hostonly=\"no\"\nadd_drivers+=\" overlay \"\n' > /etc/dracut.conf.d/91-podvm-generic.conf"
UPDATE_CMD=()
if [[ ${#SM_REGISTER[@]} -gt 0 ]]; then
    UPDATE_CMD=(--run-command "$DRACUT_CONF" \
                --run-command "dnf versionlock clear 2>/dev/null || true; dnf -y update --setopt=install_weak_deps=False --nobest && dnf -y remove --oldinstallonly 2>/dev/null || true; dnf clean all" \
                --run-command "dracut -f --regenerate-all")
fi

virt-customize --memsize 8192 \
    "${SM_REGISTER[@]}" \
    ${UPDATE_CMD[@]+"${UPDATE_CMD[@]}"} \
    --run-command "printf 'BOOT_MODE=%s\nSSHD_SERVICE=%s\n' '${BOOT_MODE:-grub}' '${SSHD_SERVICE:-true}' > /etc/podvm-build-env" \
    --run $ARTIFACTS_FOLDER/script-disk-mods.sh \
    --copy-in $ARTIFACTS_FOLDER/podvm-binaries.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/pause-bundle.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/luks-config.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/uptycs-complete.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/provision-uptycs.sh:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/uptycs-osquery.service:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/podvm-nessus-disk:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/podvm-nessus-disk.service:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/podvm-nessus-agent:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/podvm-nessus-agent.service:/tmp/ \
    --run $ARTIFACTS_FOLDER/podvm_maker.sh \
    --run $ARTIFACTS_FOLDER/install-uptycs.sh \
    "${HARDEN_ARGS[@]}" \
    ${EXTRA_ARGS} \
    -a $INPUT_IMAGE

[[ ${#SM_REGISTER[@]} -gt 0 ]] && virt-customize --memsize 8192 --run-command "subscription-manager unregister" -a $INPUT_IMAGE || true

# IBM MOD (2026-11-19, Tenable CIS 6.2.4.1): `subscription-manager unregister` above (and the register before it) writes
# /var/log/rhsm/*.log and dnf logs AFTER cis-harden.sh ran, as 0644. Re-apply the same /var/log modes as the last write to the image.
# Same exclusions as cis-harden.sh (wtmp/btmp/lastlog keep 0664 as the CIS audit allows). Hardened builds only.
if [[ -n "${HARDENED:-}" && "${HARDENED}" != "0" ]]; then
    virt-customize --memsize 8192 -a $INPUT_IMAGE \
        --run-command "find /var/log -type f ! -name 'lastlog*' ! -name 'wtmp*' ! -name 'btmp*' ! -name README -exec chmod u-x,g-wx,o-rwx {} +" \
        --run-command "test -z \"\$(find /var/log -type f ! -name 'lastlog*' ! -name 'wtmp*' ! -name 'btmp*' ! -name README -perm /0137)\""
fi
