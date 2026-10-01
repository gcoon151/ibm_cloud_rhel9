#! /bin/bash
# IBM overlay of upstream coco-podvm-scripts/example_run.sh
# Changes vs upstream:
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

sudo -E podman build -t coco-podvm \
    ${SM_SECRET_BUILD_CMD} \
    -f Dockerfile . || printf "\n\n!!! Faild to build coco-podvm, will used cached image if it exists !!!\n"

if [[ -n "${IMAGE_CERTIFICATE_PEM}" && -n "${IMAGE_PRIVATE_KEY}" ]]; then
    CERT_OPTIONS="-v $IMAGE_CERTIFICATE_PEM:/public.pem:ro,Z -v $IMAGE_PRIVATE_KEY:/private.key:ro,Z"
fi

[[ -n "$ROOT_PASSWORD" ]] && run_extras+=" -e ROOT_PASSWORD=$ROOT_PASSWORD "
[[ -n "$PODVM_BINARY" ]] && run_extras+=" -e PODVM_BINARY=$PODVM_BINARY "
[[ -n "$DEBUG_BUILD" ]] && run_extras+=" -e DEBUG_BUILD=${DEBUG_BUILD} "

[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && sudo -E podman secret create activation_key --env ACTIVATION_KEY && sudo -E podman secret create org_id --env ORG_ID && \
    SM_SECRET_RUN_CMD="--secret activation_key,type=env,target=ACTIVATION_KEY --secret org_id,type=env,target=ORG_ID "
# If DEBUG_BUILD is set, bind-mount our modified script-disk-mods.sh over the container's copy.
# This bypasses the container image cache problem (container rebuild fails without RH credentials).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -n "$DEBUG_BUILD" ]] && run_extras+=" -v ${SCRIPT_DIR}/scripts/coco/podvm/script-disk-mods.sh:/scripts/coco/podvm/script-disk-mods.sh:ro "

sudo -E podman run --rm \
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
    localhost/coco-podvm

[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && sudo podman secret rm activation_key org_id
