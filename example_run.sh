#! /bin/bash

QCOW2=${1:-${QCOW2:-~/.local/share/libvirt/images/rhel9.5-created-ks.qcow2}}
IMAGE_CERTIFICATE_PEM=$2
IMAGE_PRIVATE_KEY=$3

[[ -f $QCOW2 ]] || \
    { printf "One or more required files are missing:\n\tQCOW2=$QCOW2\n "; exit 1; }

[[ -n "${ACTIVATION_KEY}" && -n "${ORG_ID}" ]] && subscription=" --build-arg ORG_ID=${ORG_ID} --build-arg ACTIVATION_KEY=${ACTIVATION_KEY} "

if [[ -n "${IMAGE_CERTIFICATE_PEM}" && -n "${IMAGE_PRIVATE_KEY}" ]]; then
    CERT_OPTIONS="-v $IMAGE_CERTIFICATE_PEM:/public.pem:ro,Z -v $IMAGE_PRIVATE_KEY:/private.key:ro,Z"
fi

sudo podman build -t coco-podvm \
    ${subscription} \
    -f Dockerfile .

[[ -n "$ROOT_PASSWORD" ]] && run_extras+=" -e ROOT_PASSWORD=$ROOT_PASSWORD "
[[ -n "$SSHD_SERVICE" ]] && run_extras+=" -e SSHD_SERVICE=$SSHD_SERVICE "
[[ -n "$APPLY_VERITY" ]] && run_extras+=" -e APPLY_VERITY=$APPLY_VERITY "
[[ -n "$PODVM_BINARY" ]] && run_extras+=" -e PODVM_BINARY=$PODVM_BINARY "
[[ -n "$PAUSE_BUNDLE" ]] && run_extras+=" -e PAUSE_BUNDLE=$PAUSE_BUNDLE "

sudo podman run --rm \
    --privileged \
    -v $QCOW2:/disk.qcow2 \
    $CERT_OPTIONS \
    -v /lib/modules:/lib/modules:ro,Z \
    -v /boot:/boot:ro \
    -v /dev:/dev \
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/dev,target=/dev \
    --mount type=bind,source=/run/udev,target=/run/udev \
    $run_extras \
    localhost/coco-podvm

