#!/bin/bash
# Deploy and build PodVM on remote host
# Run this from your Mac laptop

set -e

# Load local .env for REMOTE_HOST if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
    source "$REPO_ROOT/.env"
fi

REMOTE_HOST="${REMOTE_HOST:-gcoon@192.168.1.196}"
BUILD_MODE="${1:-qcow2}"  # Default to qcow2
PODVM_TAG="${2:-candidate}"  # Default to 'candidate'

echo "=== Remote PodVM Build ==="
echo "Remote: $REMOTE_HOST"
echo "Mode: $BUILD_MODE"
echo "Tag: $PODVM_TAG"
echo ""

# Handle vsi-only mode - skip build, just create VSI image
if [ "$BUILD_MODE" = "vsi-only" ]; then
    echo "[1/1] Creating VSI image from latest QCOW2..."
    echo "----------------------------------------"
    "$REPO_ROOT/ibmcloud/create-vsi-image.sh"
    exit $?
fi

# Step 1: Update remote repository
echo "[1/4] Updating remote repository..."
echo "----------------------------------------"
ssh "$REMOTE_HOST" "
    cd ~/gits/ibm_cloud_rhel9
    echo 'Fetching latest changes...'
    git fetch origin
    echo 'Pulling updates...'
    git pull
    echo 'Updating submodules...'
    git submodule update --init --recursive
    echo '✓ Repository updated'
"
echo "----------------------------------------"
echo ""

# Step 2: Deploy .env file if it exists
if [ -f "$REPO_ROOT/.env" ]; then
    echo "[2/4] Deploying credentials..."
    scp -q "$REPO_ROOT/.env" "$REMOTE_HOST:~/gits/ibm_cloud_rhel9/"
    echo "✓ Credentials deployed"
else
    echo "[2/4] No .env file found - skipping credential deployment"
fi
echo ""

# Step 3: Run the build
echo "[3/4] Running build on remote host..."
echo "----------------------------------------"
BUILD_OUTPUT=$(ssh -t "$REMOTE_HOST" "
    cd ~/gits/ibm_cloud_rhel9
    PODVM_TAG=$PODVM_TAG ./build/build-podvm.sh $BUILD_MODE
" 2>&1 | tee /dev/tty)
BUILD_STATUS=$?
echo "----------------------------------------"
echo ""

# Step 4: Report results
if [ $BUILD_STATUS -eq 0 ]; then
    echo "[4/4] ✓ Build completed successfully!"
    echo ""
    
    # Extract QCOW2 filename from build output
    QCOW2_FILE=$(echo "$BUILD_OUTPUT" | grep -o 'rhel97-[0-9]*\.qcow2' | tail -1)
    
    if [ -n "$QCOW2_FILE" ]; then
        echo "QCOW2 Image: $QCOW2_FILE"
        echo ""
        echo "Next steps:"
        echo "  1. Create VSI image: $REPO_ROOT/ibmcloud/create-vsi-image.sh $QCOW2_FILE"
        echo "  2. Configure OpenShift: $REPO_ROOT/ibmcloud/configure-openshift.sh <image-id>"
        echo "  3. Test deployment: $REPO_ROOT/build/test-podvm.sh"
    fi
else
    echo "[4/4] ✗ Build failed with exit code $BUILD_STATUS"
    echo ""
    echo "Check the output above for errors"
    exit $BUILD_STATUS
fi

# Made with Bob
