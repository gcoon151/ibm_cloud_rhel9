#! /bin/bash
set -euo pipefail
# IBM overlay of upstream coco-podvm-scripts/example_run.sh
# Changes vs upstream:
#   - set -euo pipefail: any unchecked failure now exits non-zero (previously
#     podman run could crash and the caller would see exit 0)
#   - Added -v /boot:/boot:ro  (supermin needs host kernel in /boot to build appliance)
#   - Added -v /dev:/dev       (needed for nbd and block device access)
# These two mounts fix the "supermin: failed to find a suitable kernel" error
# on Ubuntu build hosts after security updates tightened vmlinuz permissions.

QCOW2=${1:-${QCOW2:-~/.local/share/libvirt/images/rhel10.1-created-ks.qcow2}}
IMAGE_CERTIFICATE_PEM=$2
IMAGE_PRIVATE_KEY=$3

[[ -f $QCOW2 ]] || \
    { printf "One or more required files are missing:\n\tQCOW2=$QCOW2\n "; exit 1; }

[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && echo "Subscription credentials have been found" && SM_SECRET_BUILD_CMD=" --secret=id=activation_key,env=ACTIVATION_KEY --secret=id=org_id,env=ORG_ID "

# NOTE: build-rhel10-overlay.sh already built coco-podvm into root's store in Step 3.
# This second build (inside example_run.sh) is a belt-and-suspenders fallback.
# sudo-rs resets env; --preserve-env passes the secrets through.
# Failure here is fatal — if the cached image is also missing we cannot proceed.
if ! sudo --preserve-env=ACTIVATION_KEY,ORG_ID podman build -t coco-podvm \
    ${SM_SECRET_BUILD_CMD} \
    -f Dockerfile .; then
    # Build failed — only continue if a cached image exists in root's store
    if ! sudo podman image exists localhost/coco-podvm; then
        echo "ERROR: podman build failed AND no cached localhost/coco-podvm image found — cannot run overlay" >&2
        exit 1
    fi
    echo "WARNING: podman build failed but cached localhost/coco-podvm exists — using cache"
fi

if [[ -n "${IMAGE_CERTIFICATE_PEM}" && -n "${IMAGE_PRIVATE_KEY}" ]]; then
    CERT_OPTIONS="-v $IMAGE_CERTIFICATE_PEM:/public.pem:ro,Z -v $IMAGE_PRIVATE_KEY:/private.key:ro,Z"
fi

[[ -n "$ROOT_PASSWORD" ]] && run_extras+=" -e ROOT_PASSWORD=$ROOT_PASSWORD "
[[ -n "$PODVM_BINARY" ]] && run_extras+=" -e PODVM_BINARY=$PODVM_BINARY "
[[ -n "$PODVM_BINARY_DIGEST" ]] && run_extras+=" -e PODVM_BINARY_DIGEST=$PODVM_BINARY_DIGEST "
[[ -n "$DEBUG_BUILD" ]] && run_extras+=" -e DEBUG_BUILD=${DEBUG_BUILD} "

# Bind-mount root's registry auth into the container so podman inside can pull from
# registry.redhat.io. sudo podman login (in build-rhel10-overlay.sh Step 4) writes
# to /run/containers/0/auth.json (owned root:root mode 600 — gcoon cannot read it,
# so -f check must use sudo test).
AUTH_JSON="/run/containers/0/auth.json"
if sudo test -f "${AUTH_JSON}"; then
    run_extras+=" -v ${AUTH_JSON}:/run/containers/0/auth.json:ro -e REGISTRY_AUTH_FILE=/run/containers/0/auth.json "
    echo "  Using registry auth: ${AUTH_JSON}"
else
    echo "WARNING: ${AUTH_JSON} not found — podman pull inside container may fail for private registries" >&2
    echo "         Run: sudo podman login registry.redhat.io first" >&2
fi

# sudo-rs (this Ubuntu build host) resets env by default; use --preserve-env so podman
# secret create can read ACTIVATION_KEY / ORG_ID from the environment.
[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && \
    sudo --preserve-env=ACTIVATION_KEY podman secret create activation_key --env ACTIVATION_KEY && \
    sudo --preserve-env=ORG_ID         podman secret create org_id         --env ORG_ID && \
    SM_SECRET_RUN_CMD="--secret activation_key,type=env,target=ACTIVATION_KEY --secret org_id,type=env,target=ORG_ID "
# If DEBUG_BUILD is set, bind-mount our modified script-disk-mods.sh over the container's copy.
# This bypasses the container image cache problem (container rebuild fails without RH credentials).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "$DEBUG_BUILD" ]] && run_extras+=" -v ${SCRIPT_DIR}/scripts/coco/podvm/script-disk-mods.sh:/scripts/coco/podvm/script-disk-mods.sh:ro "

# Clean up secrets on exit regardless of success or failure
_cleanup_secrets() {
    [[ -n "${ACTIVATION_KEY:-}" && -n "${ORG_ID:-}" ]] && \
        sudo podman secret rm activation_key org_id 2>/dev/null || true
}
trap _cleanup_secrets EXIT

echo "Running coco-podvm container overlay..."
if ! sudo podman run --rm \
    --privileged \
    -v $QCOW2:/disk.qcow2 \
    $CERT_OPTIONS \
    -v /lib/modules:/lib/modules:ro,Z \
    -v /boot:/boot:ro \
    -v /dev:/dev \
    ${SM_SECRET_RUN_CMD} \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    $run_extras \
    localhost/coco-podvm; then
    echo "" >&2
    echo "ERROR: coco-podvm container exited non-zero — overlay FAILED" >&2
    echo "       The QCOW2 at $QCOW2 is likely incomplete or corrupt." >&2
    echo "       Check the output above for 'Input/output error', 'Failed to setup verity'," >&2
    echo "       'modprobe: FATAL', or 'Process completed!' (absence = build did not finish)." >&2
    exit 1
fi
echo "✓ coco-podvm container completed successfully"
