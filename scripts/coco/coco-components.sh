#! /bin/bash

INPUT_IMAGE=$1

SCRIPT_FOLDER=${SCRIPT_FOLDER:-$(dirname $0)}
SCRIPT_FOLDER=$(realpath $SCRIPT_FOLDER)

PODVM_BINARY_DEF=quay.io/rh-ee-gcoon/podvm_binaries:candidate
PODVM_BINARY_LOCATION_DEF=/podvm-binaries.tar.gz
PAUSE_BUNDLE_DEF=quay.io/rh-ee-gcoon/podvm_binaries:candidate
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
[[ -n "$ROOT_PASSWORD" ]] && EXTRA_ARGS=" --root-password password:${ROOT_PASSWORD} "

# Check if Uptycs files exist before adding them to virt-customize
UPTYCS_COPY_ARGS=""
UPTYCS_RUN_ARGS=""
if [ -f "$ARTIFACTS_FOLDER/uptycs-complete.tar.gz" ]; then
    echo "Found Uptycs package, will install into image"
    # Copy Uptycs files to /tmp/ in the VM image (same pattern as other files)
    UPTYCS_COPY_ARGS="--copy-in $ARTIFACTS_FOLDER/uptycs-complete.tar.gz:/tmp/ "
    
    if [ -f "$ARTIFACTS_FOLDER/provision-uptycs.sh" ]; then
        UPTYCS_COPY_ARGS="$UPTYCS_COPY_ARGS --copy-in $ARTIFACTS_FOLDER/provision-uptycs.sh:/tmp/ "
    fi
    
    if [ -f "$ARTIFACTS_FOLDER/uptycs-osquery.service" ]; then
        UPTYCS_COPY_ARGS="$UPTYCS_COPY_ARGS --copy-in $ARTIFACTS_FOLDER/uptycs-osquery.service:/tmp/ "
    fi
    
    # Run install script after podvm_maker.sh
    UPTYCS_RUN_ARGS="--run $ARTIFACTS_FOLDER/install-uptycs.sh "
else
    echo "Uptycs binary not found, skipping Uptycs installation"
fi

# Add kata-agent metrics configuration if it exists
METRICS_COPY_ARGS=""
METRICS_RUN_ARGS=""
METRICS_CONF="$ARTIFACTS_FOLDER/../konflux/podvm-root/etc/systemd/system/kata-agent.service.d/20-enable-metrics.conf"
if [ -f "$METRICS_CONF" ]; then
    echo "Found kata-agent metrics configuration, will install into image"
    # Copy metrics config to /tmp/ in the VM image (same pattern as Uptycs)
    METRICS_COPY_ARGS="--copy-in $METRICS_CONF:/tmp/ "
    
    # Run install script after Uptycs
    METRICS_RUN_ARGS="--run $ARTIFACTS_FOLDER/install-metrics-config.sh "
else
    echo "Warning: kata-agent metrics configuration not found at $METRICS_CONF"
fi

# Enable debug mode to see what virt-customize is doing
export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1

# Remove old kernel if multiple kernels are present (CVE-2026-31431 fix)
# This handles the case where kickstart installed both old and new kernels
echo "Checking for old kernels to remove..."
OLD_KERNEL_REMOVAL="
KERNEL_COUNT=\$(rpm -q kernel-uki-virt | wc -l)
if [ \$KERNEL_COUNT -gt 1 ]; then
    echo 'Multiple kernels found, removing old kernel...'
    OLD_KERNEL=\$(rpm -q kernel-uki-virt | sort -V | head -n 1)
    OLD_VERSION=\$(echo \$OLD_KERNEL | sed 's/kernel-uki-virt-//')
    echo \"Removing: \$OLD_KERNEL and kernel-modules-core-\$OLD_VERSION\"
    dnf remove -y --setopt=protected_packages= kernel-uki-virt-\$OLD_VERSION kernel-modules-core-\$OLD_VERSION || true
    echo 'Old kernel removal complete'
else
    echo 'Only one kernel found, no removal needed'
fi
"

virt-customize \
    --copy-in $ARTIFACTS_FOLDER/podvm-binaries.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/pause-bundle.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/luks-config.tar.gz:/tmp/ \
    ${UPTYCS_COPY_ARGS} \
    ${METRICS_COPY_ARGS} \
    --run-command "$OLD_KERNEL_REMOVAL" \
    --run $ARTIFACTS_FOLDER/podvm_maker.sh \
    ${UPTYCS_RUN_ARGS} \
    ${METRICS_RUN_ARGS} \
    --uninstall WALinuxAgent \
    ${EXTRA_ARGS} \
    -a $INPUT_IMAGE
