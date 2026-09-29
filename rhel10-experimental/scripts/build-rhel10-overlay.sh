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
#   IBMCLOUD_API_KEY   IBM Cloud API key for COS upload + VSI image creation
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

# Validate required vars (IBMCLOUD_API_KEY only needed for upload step, not the overlay itself)
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

# ---------------------------------------------------------------------------
# STEP 1: Verify partition GUID on base QCOW2
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 1: Verifying partition GUID ---"
RAW_TMP=$(mktemp /tmp/rhel10-check-XXXXXX.raw)
qemu-img convert -f qcow2 -O raw "${BASE_QCOW2}" "${RAW_TMP}"
ROOT_GUID=$(sfdisk -d "${RAW_TMP}" 2>/dev/null | grep -E 'part[23]' | grep -o 'type=[0-9A-Fa-f-]*' | cut -d= -f2 | grep -i "4F68BCE3" || true)
rm -f "${RAW_TMP}"
if [[ -z "${ROOT_GUID}" ]]; then
    echo "⚠ Root partition GUID may be wrong — will fix via virt-customize in overlay"
else
    echo "✓ Root partition GUID correct (4F68BCE3...)"
fi

# ---------------------------------------------------------------------------
# STEP 2: Prepare coco-podvm-scripts with our IBM overlays
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 2: Preparing coco-podvm-scripts ---"
if [[ ! -d "${COCO_SCRIPTS_DIR}" ]]; then
    git clone https://github.com/confidential-devhub/coco-podvm-scripts.git "${COCO_SCRIPTS_DIR}"
fi
# Overlay our IBM-specific scripts
cp "${REPO_ROOT}/ibm_cloud_rhel9/scripts/coco/podvm/podvm_maker.sh"   "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
cp "${REPO_ROOT}/ibm_cloud_rhel9/scripts/coco/podvm/install-uptycs.sh"   "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
cp "${REPO_ROOT}/ibm_cloud_rhel9/scripts/coco/podvm/provision-uptycs.sh" "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
mkdir -p "${COCO_SCRIPTS_DIR}/services"
cp "${REPO_ROOT}/ibm_cloud_rhel9/services/uptycs-osquery.service" "${COCO_SCRIPTS_DIR}/services/"
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
# STEP 4: Login to registry and run overlay
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 4: Running CoCo + Uptycs overlay ---"
podman login registry.redhat.io --username "${RH_USERNAME}" --password "${RH_PASSWORD}"

cp "${BASE_QCOW2}" "${OUTPUT_QCOW2}"

podman run --rm \
    --privileged \
    -v "${OUTPUT_QCOW2}:/disk.qcow2" \
    -v /lib/modules:/lib/modules:ro,Z \
    -v /boot:/boot:ro \
    -v /dev:/dev \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    -e PODVM_BINARY="registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9:${PAYLOAD_TAG}" \
    -e NVIDIA_DRIVER_VERSION="" \
    -e SSHD_SERVICE="${SSHD_SERVICE}" \
    localhost/coco-podvm

echo "✓ Overlay complete: ${OUTPUT_QCOW2}"
qemu-img info "${OUTPUT_QCOW2}"

echo ""
echo "Next steps:"
echo "  Upload: ibmcloud cos upload --bucket ${COS_BUCKET} --key $(basename ${OUTPUT_QCOW2}) --file ${OUTPUT_QCOW2} --region ${COS_REGION}"
echo "  Then:   ibmcloud is image-create podvm-candidate-${OUTPUT_PREFIX}-${DATE} --file cos://${COS_REGION}/${COS_BUCKET}/$(basename ${OUTPUT_QCOW2}) --os-name red-10-amd64"
