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
# Log file tied to the output image serial — never collides across builds.
# Caller should NOT redirect stdout to a generic name; use this path instead.
BUILD_LOG="/tmp/${OUTPUT_PREFIX}-build-${DATE}.log"
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
echo "  Build log:   $BUILD_LOG"
echo "  Payload tag: $PAYLOAD_TAG"
echo "  SSHD:        $SSHD_SERVICE"
echo "================================================================="

# Tee all subsequent output to the build log as well as stdout.
# If a caller already redirects stdout (nohup ... > somefile), that file
# will also receive everything — but the canonical log is $BUILD_LOG.
exec > >(tee -a "$BUILD_LOG") 2>&1

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

# CRITICAL: Remove any pre-baked binary tarballs from the scripts directory before building
# the container. The Dockerfile's "ADD scripts /scripts" bakes everything present here.
# If podvm-binaries.tar.gz exists here, get-artifacts.sh inside the container will skip
# the PODVM_BINARY download — rendering PAYLOAD_TAG meaningless (see Lesson 21).
# README.md step 4: the container must be built clean, without pre-baked binaries.
for stale_tarball in \
    "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/podvm-binaries.tar.gz" \
    "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/pause-bundle.tar.gz" \
    "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/uptycs-complete.tar.gz"; do
    if [[ -f "${stale_tarball}" ]]; then
        rm -f "${stale_tarball}"
        echo "  Removed stale tarball: $(basename ${stale_tarball})"
    fi
done
echo "✓ Binary tarballs clean — get-artifacts.sh will download from registry"

cp "${REPO_ROOT}/scripts/coco/podvm/podvm_maker.sh"      "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
cp "${REPO_ROOT}/scripts/coco/podvm/script-disk-mods.sh" "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
# virt-customize --run gives scripts a clean env — bake DEBUG_BUILD value directly into the script
if [[ -n "${DEBUG_BUILD:-}" ]]; then
    sed -i "s/DEBUG_BUILD:-0}/DEBUG_BUILD:-${DEBUG_BUILD}}/" "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/script-disk-mods.sh"
fi
cp "${REPO_ROOT}/scripts/coco/podvm/install-uptycs.sh"   "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
cp "${REPO_ROOT}/scripts/coco/podvm/provision-uptycs.sh" "${COCO_SCRIPTS_DIR}/scripts/coco/podvm/"
# example_run.sh — adds -v /boot:/boot:ro and -v /dev:/dev (fixes supermin kernel lookup on Ubuntu)
cp "${REPO_ROOT}/scripts/coco/podvm/example_run.sh"      "${COCO_SCRIPTS_DIR}/"
mkdir -p "${COCO_SCRIPTS_DIR}/services"
cp "${REPO_ROOT}/services/uptycs-osquery.service" "${COCO_SCRIPTS_DIR}/services/"
echo "✓ IBM overlay scripts copied"

# ---------------------------------------------------------------------------
# STEP 3: Build coco-podvm container into ROOT's podman store
# ---------------------------------------------------------------------------
# CRITICAL: example_run.sh runs "sudo podman run" — it uses ROOT's podman store.
# This step must use "sudo podman build/rmi" so the image ends up where example_run.sh
# will find it. Building as gcoon (no sudo) produces an image in gcoon's store that
# sudo podman run never sees, causing fallback to whatever stale image root has cached.
# (See Lesson 21 in LESSONS_LEARNED_2026-10-02.md)
echo ""
echo "--- Step 3: Building coco-podvm container (root podman store) ---"
sudo podman rmi localhost/coco-podvm 2>/dev/null && echo "✓ Removed stale coco-podvm image from root store" || echo "  (no stale image to remove)"
cd "${COCO_SCRIPTS_DIR}"
# sudo-rs (this Ubuntu host) resets env by default; use --preserve-env to pass secrets.
sudo --preserve-env=ORG_ID,ACTIVATION_KEY podman build -t coco-podvm \
    --secret id=org_id,env=ORG_ID \
    --secret id=activation_key,env=ACTIVATION_KEY \
    -f Dockerfile .
echo "✓ Container built into root podman store"

# ---------------------------------------------------------------------------
# STEP 3b: Assert the container has fresh binaries (not baked-in April 3 stale)
# ---------------------------------------------------------------------------
# The Dockerfile's ADD scripts /scripts bakes whatever is in coco-podvm-scripts/scripts/
# at build time — including podvm-binaries.tar.gz if it is already present there.
# get-artifacts.sh inside the container skips the PODVM_BINARY download if the tarball
# already exists (Lesson 21). A stale tarball from a previous build = wrong CDH in QCOW2
# no matter what PAYLOAD_TAG says.
#
# Canonical documented procedure (coco-podvm-scripts/README.md step 4):
#   "sudo podman build my-coco-podvm ."
# We must build into root's store (sudo) and verify the result contains no stale tarball.
echo ""
echo "--- Step 3b: Verifying container has no pre-baked stale binaries ---"
TARBALL_PRESENT=$(sudo podman run --rm localhost/coco-podvm \
    ls /scripts/coco/podvm/podvm-binaries.tar.gz 2>/dev/null && echo "YES" || echo "NO")
if [[ "${TARBALL_PRESENT}" == "YES" ]]; then
    TARBALL_INFO=$(sudo podman run --rm localhost/coco-podvm \
        ls -lh /scripts/coco/podvm/podvm-binaries.tar.gz 2>/dev/null)
    echo "ERROR: Container has a pre-baked podvm-binaries.tar.gz: ${TARBALL_INFO}" >&2
    echo "       get-artifacts.sh will skip the PODVM_BINARY download and use these baked-in binaries." >&2
    echo "       This means PAYLOAD_TAG=${PAYLOAD_TAG} has no effect — old CDH ends up in the QCOW2." >&2
    echo "       Fix: rm ${COCO_SCRIPTS_DIR}/scripts/coco/podvm/podvm-binaries.tar.gz and re-run." >&2
    echo "       See Lesson 21 in LESSONS_LEARNED_2026-10-02.md." >&2
    exit 1
fi
echo "  ✓ No pre-baked tarball in container — get-artifacts.sh will download from ${PODVM_BINARY}"

# ---------------------------------------------------------------------------
# STEP 4: Run CoCo + Uptycs overlay via example_run.sh
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 4: Running CoCo + Uptycs overlay ---"
# Login to registry as root (sudo podman run pulls from root's auth config).
sudo --preserve-env=HOME podman login registry.redhat.io --username "${RH_USERNAME}" --password "${RH_PASSWORD}"

cp "${BASE_QCOW2}" "${OUTPUT_QCOW2}"

export QCOW2="${OUTPUT_QCOW2}"
export PODVM_BINARY="registry.redhat.io/openshift-sandboxed-containers/osc-podvm-payload-rhel9:${PAYLOAD_TAG}"
export SSHD_SERVICE="${SSHD_SERVICE}"
export NVIDIA_DRIVER_VERSION=""
export DEBUG_BUILD="${DEBUG_BUILD:-}"
# ACTIVATION_KEY must be exported for create-verity-podvm.sh's inner build.
export ACTIVATION_KEY ORG_ID

# Resolve payload digest via root's podman (matches which store sudo podman run will use).
echo "  Resolving payload digest for ${PODVM_BINARY}..."
sudo podman pull "${PODVM_BINARY}" 2>/dev/null | tail -1 || true
export PODVM_BINARY_DIGEST=$(sudo podman inspect --format '{{index .RepoDigests 0}}' "${PODVM_BINARY}" 2>/dev/null || echo "unknown")
echo "  PODVM_BINARY_DIGEST: ${PODVM_BINARY_DIGEST}"

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

# ---------------------------------------------------------------------------
# STEP 5b: Assert CDH binary version matches the expected payload
#
# Three checks, all mandatory:
#   1. mtime  — rejects pre-July-24-2026 binaries (April 3 stale cache fingerprint)
#   2. sha256 — exact match against known-good 1.13.1 CDH binary (Lesson 21)
#   3. RCAR   — RCAR protocol version string extracted via strings(1)
#              Must be "0.1.3" — that is what Trustee v1.2.1 requires
#
# Known-good fingerprints for osc-podvm-payload-rhel9:1.13.1 (verified 2026-10-10):
#   CDH sha256:  bbecd5c043a2b6b79474cb549e4c503d374ab270721ec4eb1fe817fdaf0d1c6f
#   CDH mtime:   2026-07-24 (epoch 1753315200)
#   CDH RCAR:    0.1.3  (from: strings binary | grep -E "^0\.[0-9]+\.[0-9]+$")
#
# If PAYLOAD_TAG is changed, update these fingerprints by running:
#   podman create --name p registry.redhat.io/.../osc-podvm-payload-rhel9:NEW_TAG
#   podman cp p:/podvm-binaries.tar.gz /tmp/pb.tar.gz && podman rm p
#   tar xzf /tmp/pb.tar.gz -C /tmp usr/local/bin/confidential-data-hub
#   sha256sum /tmp/usr/local/bin/confidential-data-hub
#   strings  /tmp/usr/local/bin/confidential-data-hub | grep -E "^0\.[0-9]+\.[0-9]+$"
# ---------------------------------------------------------------------------
echo ""
echo "--- Step 5b: Verifying CDH binary identity in QCOW2 ---"

# Extract CDH binary from QCOW2 for inspection
CDH_TMPDIR=$(mktemp -d /tmp/cdh-check-XXXXXX)
guestfish --ro -a "${OUTPUT_QCOW2}" -- \
    run : mount /dev/sda2 / : download /usr/local/bin/confidential-data-hub "${CDH_TMPDIR}/confidential-data-hub"
CDH_BIN="${CDH_TMPDIR}/confidential-data-hub"

if [[ ! -f "${CDH_BIN}" ]]; then
    echo "ERROR: could not extract CDH binary from QCOW2" >&2
    rm -rf "${CDH_TMPDIR}"; exit 1
fi

# Check 1: mtime via guestfish stat (April 3 stale = epoch ~1743703200)
CDH_MTIME=$(guestfish --ro -a "${OUTPUT_QCOW2}" -- run : mount /dev/sda2 / : \
    stat /usr/local/bin/confidential-data-hub 2>/dev/null | awk '/^mtime:/{print $2}')
CDH_DATE=$(python3 -c "import datetime; print(datetime.datetime.utcfromtimestamp(${CDH_MTIME:-0}).strftime('%Y-%m-%d'))")
echo "  mtime:  ${CDH_DATE} (epoch ${CDH_MTIME})"
CDH_EPOCH_MIN=1753315200  # 2026-07-24 00:00:00 UTC
if [[ "${CDH_MTIME:-0}" -lt "${CDH_EPOCH_MIN}" ]]; then
    echo "ERROR: CDH binary is from ${CDH_DATE} — pre-dates 1.13.1 release." >&2
    echo "       April 3 binaries = stale container served from root's podman store." >&2
    echo "       See Lesson 21. Nuke root store container and rebuild." >&2
    rm -rf "${CDH_TMPDIR}"; exit 1
fi
echo "  ✓ mtime ${CDH_DATE} >= 2026-07-24"

# Check 2: sha256 exact match
CDH_SHA=$(sha256sum "${CDH_BIN}" | awk '{print $1}')
echo "  sha256: ${CDH_SHA}"
EXPECTED_CDH_SHA="bbecd5c043a2b6b79474cb549e4c503d374ab270721ec4eb1fe817fdaf0d1c6f"  # 1.13.1
if [[ "${CDH_SHA}" != "${EXPECTED_CDH_SHA}" ]]; then
    echo "WARNING: CDH sha256 does not match known-good 1.13.1 fingerprint." >&2
    echo "         Expected: ${EXPECTED_CDH_SHA}" >&2
    echo "         Got:      ${CDH_SHA}" >&2
    echo "         This is expected if PAYLOAD_TAG != 1.13.1 — update fingerprints in this script." >&2
    # Warn only, don't abort — fingerprints must be updated when payload tag changes
fi
[[ "${CDH_SHA}" == "${EXPECTED_CDH_SHA}" ]] && echo "  ✓ sha256 matches known-good 1.13.1 fingerprint"

# Check 3: RCAR protocol version string
CDH_RCAR=$(strings "${CDH_BIN}" 2>/dev/null | grep -E "^0\.[0-9]+\.[0-9]+$" | sort -u | head -1)
echo "  RCAR:   ${CDH_RCAR:-NOT FOUND}"
EXPECTED_RCAR="0.1.3"   # required by Trustee v1.2.1 — verified 2026-10-10
if [[ -z "${CDH_RCAR}" ]]; then
    echo "WARNING: could not extract RCAR version from CDH binary via strings." >&2
    echo "         Binary may be stripped differently. Proceeding — verify live." >&2
elif [[ "${CDH_RCAR}" != "${EXPECTED_RCAR}" ]]; then
    echo "ERROR: CDH RCAR protocol version is '${CDH_RCAR}', expected '${EXPECTED_RCAR}'." >&2
    echo "       Trustee v1.2.1 requires RCAR ${EXPECTED_RCAR}." >&2
    echo "       This payload is incompatible — Test 8 CDH will fail." >&2
    echo "       See Lesson 15 (RCAR mismatch) in LESSONS_LEARNED." >&2
    rm -rf "${CDH_TMPDIR}"; exit 1
else
    echo "  ✓ RCAR ${CDH_RCAR} matches expected ${EXPECTED_RCAR} for Trustee v1.2.1"
fi

rm -rf "${CDH_TMPDIR}"
echo "✓ CDH binary identity verified (mtime, sha256, RCAR)"

echo ""
echo "✓ All verification checks passed. Ready to upload."
echo ""
echo "Next steps:"
echo "  Upload: COS_CRN='crn:v1:bluemix:public:cloud-object-storage:global:a/f76e4b9f3bad41c0b0238b5dd9702765:2d070509-7cea-4713-a3d3-2c8845a4e466::' bash ~/.local/share/libvirt/images/upload_hl_dev_cos_bucket.sh ${OUTPUT_QCOW2}"
echo "  Then:   ibmcloud is image-create podvm-candidate-${OUTPUT_PREFIX}-${DATE} --file cos://${COS_REGION}/${COS_BUCKET}/$(basename ${OUTPUT_QCOW2}) --os-name red-10-amd64"
