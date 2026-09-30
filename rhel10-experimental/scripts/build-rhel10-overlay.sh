#!/usr/bin/env bash
# =============================================================================
# build-rhel10-overlay.sh
#
# Run the CoCo + Uptycs overlay on a RHEL 10 base QCOW2 from Image Builder.
# Designed to run on the RHEL 9 build host (gcoon@192.168.1.196).
#
# Usage:
#   ./rhel10-experimental/scripts/build-rhel10-overlay.sh <path-to-base.qcow2>
#
# Required env vars (or set in .env at repo root):
#   RH_USERNAME        registry.redhat.io username
#   RH_PASSWORD        registry.redhat.io password
#   ORG_ID             Red Hat org ID for subscription-manager
#   ACTIVATION_KEY     Red Hat activation key
#
# Optional env vars:
#   PAYLOAD_TAG        OSC payload tag (default: 1.13.1)
#   SSHD_SERVICE       true (default, SSH enabled) or false (hardened)
#   OUTPUT_PREFIX      QCOW2 output name prefix (default: rhel10)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load .env
if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a; source "${REPO_ROOT}/.env"; set +a
    echo "✓ Loaded .env"
fi

# Args
BASE_QCOW2="${1:-}"
if [[ -z "${BASE_QCOW2}" || ! -f "${BASE_QCOW2}" ]]; then
    echo "Usage: $0 <path-to-rhel10-base.qcow2>"
    exit 1
fi

# Defaults
PAYLOAD_TAG="${PAYLOAD_TAG:-1.13.1}"
SSHD_SERVICE="${SSHD_SERVICE:-true}"
OUTPUT_PREFIX="${OUTPUT_PREFIX:-rhel10}"
DATE=$(date -u +%Y%m%d%H)
OUTPUT_QCOW2="/tmp/${OUTPUT_PREFIX}-${DATE}.qcow2"
COCO_SCRIPTS_DIR="${REPO_ROOT}/rhel10-experimental/coco-podvm-scripts"
COS_BUCKET="coon-coco-us-east"
COS_REGION="us-east"

# Validate required vars
MISSING=()
[[ -z "${RH_USERNAME:-}" ]]      && MISSING+=("RH_USERNAME")
[[ -z "${RH_PASSWORD:-}" ]]      && MISSING+=("RH_PASSWORD")
[[ -z "${ORG_ID:-}" ]]           && MISSING+=("ORG_ID")
[[ -z "${ACTIVATION_KEY:-}" ]]   && MISSING+=("ACTIVATION_KEY")
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: Missing required variables:"; printf '  - %s\n' "${MISSING[@]}"; exit 1
fi

echo "================================================================="
echo "RHEL 10 peer pod overlay build"
echo "  Base QCOW2:  $BASE_QCOW2"
echo "  Output:      $OUTPUT_QCOW2"
echo "  Payload tag: $PAYLOAD_TAG"
echo "  SSHD:        $SSHD_SERVICE"
echo "================================================================="

# Verify host tools
for tool in sgdisk qemu-img qemu-nbd guestfish; do
    command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found on host" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# STEP 1: Verify partition GUIDs on base QCOW2 (hard stop — never auto-fix)
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 1: Verifying partition GUIDs ---"
RAW_TMP=$(mktemp /tmp/rhel10-check-XXXXXX.raw)
qemu-img convert -f qcow2 -O raw "${BASE_QCOW2}" "${RAW_TMP}"
ROOT_GUID=$(sfdisk -d "${RAW_TMP}" 2>/dev/null | grep -i "type=4F68BCE3" || true)
EFI_GUID=$(sfdisk  -d "${RAW_TMP}" 2>/dev/null | grep -i "type=C12A7328" || true)
rm -f "${RAW_TMP}"
if [[ -z "${ROOT_GUID}" || -z "${EFI_GUID}" ]]; then
    echo "ERROR: Partition GUIDs wrong in base QCOW2 — this is a kickstart problem, not fixable here." >&2
    echo "  Root GUID (4F68BCE3) found: ${ROOT_GUID:-MISSING}" >&2
    echo "  EFI GUID  (C12A7328) found: ${EFI_GUID:-MISSING}" >&2
    exit 1
fi
echo "✓ EFI partition GUID correct (C12A7328...)"
echo "✓ Root partition GUID correct (4F68BCE3...)"

# ---------------------------------------------------------------------------
# STEP 2: Prepare coco-podvm-scripts with our IBM overlays
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: Preparing coco-podvm-scripts ---"
if [[ ! -d "${COCO_SCRIPTS_DIR}" ]]; then
    git clone https://github.com/confidential-devhub/coco-podvm-scripts.git "${COCO_SCRIPTS_DIR}"
fi
cp "${REPO_ROOT}/scripts/coco/podvm/podvm_maker.sh"      "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
cp "${REPO_ROOT}/scripts/coco/podvm/script-disk-mods.sh" "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
cp "${REPO_ROOT}/scripts/coco/podvm/install-uptycs.sh"   "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
cp "${REPO_ROOT}/scripts/coco/podvm/provision-uptycs.sh" "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
# example_run.sh — adds -v /boot:/boot:ro and -v /dev:/dev (fixes supermin kernel lookup on Ubuntu)
cp "${REPO_ROOT}/scripts/coco/podvm/example_run.sh"      "${COCO_SCRIPTS_DIR}/"
mkdir -p "${COCO_SCRIPTS_DIR}/services"
cp "${REPO_ROOT}/services/uptycs-osquery.service" "${COCO_SCRIPTS_DIR}/services/"
echo "✓ IBM overlay scripts copied"

# ---------------------------------------------------------------------------
# STEP 3: Build coco-podvm container
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 3: Building coco-podvm container ---"
cd "${COCO_SCRIPTS_DIR}"
export ORG_ID ACTIVATION_KEY
podman build -t coco-podvm \
    --secret id=org_id,env=ORG_ID \
    --secret id=activation_key,env=ACTIVATION_KEY \
    -f Dockerfile .
echo "✓ Container built"

# ---------------------------------------------------------------------------
# STEP 4: Run CoCo + Uptycs overlay via example_run.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 4: Running CoCo + Uptycs overlay ---"
podman login registry.redhat.io --username "${RH_USERNAME}" --password "${RH_PASSWORD}"

cp "${BASE_QCOW2}" "${OUTPUT_QCOW2}"

export QCOW2="${OUTPUT_QCOW2}"
export PODVM_BINARY="registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9:${PAYLOAD_TAG}"
export SSHD_SERVICE="${SSHD_SERVICE}"
export NVIDIA_DRIVER_VERSION=""

cd "${COCO_SCRIPTS_DIR}"
bash example_run.sh "${OUTPUT_QCOW2}"
cd "${REPO_ROOT}"

echo "✓ Overlay complete: ${OUTPUT_QCOW2}"
qemu-img info "${OUTPUT_QCOW2}"

# ---------------------------------------------------------------------------
# STEP 5: Mandatory local verification — ALL checks must pass before upload
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 5: Local QCOW2 verification (must pass before upload) ---"
VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify-qcow2.sh"
if [[ ! -f "${VERIFY_SCRIPT}" ]]; then
    echo "ERROR: verify-qcow2.sh not found at ${VERIFY_SCRIPT}" >&2; exit 1
fi
bash "${VERIFY_SCRIPT}" "${OUTPUT_QCOW2}"

echo ""
echo "✓ All verification checks passed. Ready to upload."
echo ""
echo "Next steps:"
echo "  Upload: COS_CRN='crn:v1:bluemix:public:cloud-object-storage:global:a/f76e4b9f3bad41c0b0238b5dd9702765:2d070509-7cea-4713-a3d3-2c8845a4e466::' bash ~/.local/share/libvirt/images/upload_hl_dev_cos_bucket.sh ${OUTPUT_QCOW2}"
echo "  Then:   ibmcloud is image-create podvm-candidate-${OUTPUT_PREFIX}-${DATE} --file cos://${COS_REGION}/${COS_BUCKET}/$(basename ${OUTPUT_QCOW2}) --os-name red-10-amd64"
