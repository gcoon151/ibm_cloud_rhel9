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
    echo "Found Uptycs complete package, will install into image"
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

# Check if dm-verity configuration service exists (two-stage boot approach)
DMVERITY_COPY_ARGS=""
DMVERITY_RUN_ARGS=""
if [ -f "$ARTIFACTS_FOLDER/dmverity-configure.service" ] && [ -f "$ARTIFACTS_FOLDER/configure-dmverity.sh" ] && [ -f "$ARTIFACTS_FOLDER/install-dmverity-configure.sh" ]; then
    echo "Found dm-verity configuration service, will install for two-stage boot"
    DMVERITY_COPY_ARGS="--copy-in $ARTIFACTS_FOLDER/dmverity-configure.service:/tmp/ "
    DMVERITY_COPY_ARGS="$DMVERITY_COPY_ARGS --copy-in $ARTIFACTS_FOLDER/configure-dmverity.sh:/tmp/ "
    DMVERITY_RUN_ARGS="--run $ARTIFACTS_FOLDER/install-dmverity-configure.sh "
else
    echo "dm-verity configuration service not found, skipping dm-verity installation"
fi

# Note: Per-container metrics functionality has been abandoned
# Metrics configuration code removed to eliminate warning messages
METRICS_COPY_ARGS=""
METRICS_RUN_ARGS=""

virt-customize \
    --copy-in $ARTIFACTS_FOLDER/podvm-binaries.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/pause-bundle.tar.gz:/tmp/ \
    --copy-in $ARTIFACTS_FOLDER/luks-config.tar.gz:/tmp/ \
    ${UPTYCS_COPY_ARGS} \
    ${DMVERITY_COPY_ARGS} \
    ${METRICS_COPY_ARGS} \
    --run $ARTIFACTS_FOLDER/podvm_maker.sh \
    ${UPTYCS_RUN_ARGS} \
    ${DMVERITY_RUN_ARGS} \
    ${METRICS_RUN_ARGS} \
    --uninstall WALinuxAgent \
    ${EXTRA_ARGS} \
    -a $INPUT_IMAGE

# Note: systemd-ukify and binutils are NOT removed here
# They are needed by verity.sh which runs after this script
# verity.sh will remove them after UKI modification is complete
