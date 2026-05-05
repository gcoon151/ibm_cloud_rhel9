#!/bin/bash
# Build PodVM on remote host
# Run this from your Mac laptop in the EDR project directory

set -e

# Capture command-line environment variables before loading .env
CMD_SSHD_SERVICE="${SSHD_SERVICE:-}"
CMD_APPLY_VERITY="${APPLY_VERITY:-}"

# Load local .env for REMOTE_HOST if it exists
if [ -f .env ]; then
    source .env
fi

# Command-line environment variables take precedence over .env
REMOTE_HOST="${REMOTE_HOST:-gcoon@192.168.1.196}"
BUILD_MODE="${1:-qcow2}"  # Default to qcow2, can pass 'all', 'binaries', 'vsi-only', or 'qcow2-only'
PODVM_TAG="${2:-candidate}"  # Default to 'candidate', can specify custom tag
SSHD_SERVICE="${CMD_SSHD_SERVICE:-${SSHD_SERVICE:-true}}"  # Command-line > .env > default
APPLY_VERITY="${CMD_APPLY_VERITY:-${APPLY_VERITY:-false}}"  # Command-line > .env > default

echo "=== Remote PodVM Build ==="
echo "Remote: $REMOTE_HOST"
echo "Mode: $BUILD_MODE"
echo "Tag: $PODVM_TAG"
echo "SSHD Service: $SSHD_SERVICE"
echo "Apply dm-verity: $APPLY_VERITY"
echo ""

# Handle vsi-only mode - skip build, just create VSI image
if [ "$BUILD_MODE" = "vsi-only" ]; then
    echo "[1/1] Creating VSI image from latest QCOW2..."
    echo "----------------------------------------"
    ./scripts/create-vsi-image.sh
    exit $?
fi

# Handle qcow2-only mode - build QCOW2 but skip COS upload and VSI creation
if [ "$BUILD_MODE" = "qcow2-only" ]; then
    echo "Mode: qcow2-only (will skip COS upload and VSI creation)"
    SKIP_UPLOAD="--skip-upload"
    REMOTE_BUILD_MODE="qcow2"  # Map to 'qcow2' for build-podvm.sh
else
    SKIP_UPLOAD=""
    REMOTE_BUILD_MODE="$BUILD_MODE"
fi

# Deploy latest build script, EDR files, and .env file
echo "[1/3] Deploying build script, EDR files, and credentials..."
scp -q scripts/build-podvm.sh "$REMOTE_HOST:~/"
ssh "$REMOTE_HOST" 'chmod +x ~/build-podvm.sh'

# Deploy EDR systemd service files, scripts, and binary to the coco-podvm-scripts directory
echo "  → Deploying core build files to build directory..."

# Deploy scripts directly (SSH disable now handled in create-verity-podvm.sh)
scp -q ibm_cloud_rhel9/scripts/coco/podvm/podvm_maker.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
scp -q ibm_cloud_rhel9/scripts/coco/coco-components.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/"
scp -q ibm_cloud_rhel9/scripts/create-verity-podvm.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/"
scp -q ibm_cloud_rhel9/example_run.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/"
echo "  ✓ Deployed: podvm_maker.sh, coco-components.sh, create-verity-podvm.sh, example_run.sh"

echo "  → Deploying Uptycs EDR files to build directory..."
scp -q ibm_cloud_rhel9/scripts/coco/podvm/uptycs-osquery.service "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
scp -q ibm_cloud_rhel9/scripts/coco/podvm/provision-uptycs.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
scp -q ibm_cloud_rhel9/scripts/coco/podvm/install-uptycs.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
echo "  ✓ Deployed: uptycs-osquery.service, provision-uptycs.sh, install-uptycs.sh"

# Detect which branch we're on in the submodule
SUBMODULE_BRANCH=$(cd ibm_cloud_rhel9 && git branch --show-current)
echo "  → Detected submodule branch: $SUBMODULE_BRANCH"

# Deploy dm-verity files only if they exist (dmverity branch)
if [ -f "ibm_cloud_rhel9/scripts/coco/podvm/dmverity-configure.service" ]; then
    echo "  → Deploying dm-verity configuration service..."
    scp -q ibm_cloud_rhel9/scripts/coco/podvm/dmverity-configure.service "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
    scp -q ibm_cloud_rhel9/scripts/coco/podvm/configure-dmverity.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
    scp -q ibm_cloud_rhel9/scripts/coco/podvm/install-dmverity-configure.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
    echo "  ✓ Deployed: dmverity-configure.service, configure-dmverity.sh, install-dmverity-configure.sh"
    
    echo "  → Deploying verity scripts..."
    scp -q ibm_cloud_rhel9/scripts/verity/verity.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/verity/"
    scp -q ibm_cloud_rhel9/scripts/create-verity-podvm.sh "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/"
    
    # Set permissions for all files including dm-verity
    ssh "$REMOTE_HOST" 'chmod +x ~/gits/coco-podvm-scripts/scripts/verity/verity.sh ~/gits/coco-podvm-scripts/scripts/create-verity-podvm.sh ~/gits/coco-podvm-scripts/scripts/coco/podvm/install-dmverity-configure.sh ~/gits/coco-podvm-scripts/scripts/coco/podvm/configure-dmverity.sh ~/gits/coco-podvm-scripts/scripts/coco/podvm/podvm_maker.sh ~/gits/coco-podvm-scripts/scripts/coco/podvm/install-uptycs.sh ~/gits/coco-podvm-scripts/scripts/coco/podvm/provision-uptycs.sh ~/gits/coco-podvm-scripts/scripts/coco/coco-components.sh ~/gits/coco-podvm-scripts/example_run.sh'
    echo "  ✓ dm-verity ENABLED (branch: $SUBMODULE_BRANCH)"
else
    # Set permissions for core files including Uptycs scripts
    ssh "$REMOTE_HOST" 'chmod +x ~/gits/coco-podvm-scripts/scripts/coco/podvm/podvm_maker.sh ~/gits/coco-podvm-scripts/scripts/coco/podvm/install-uptycs.sh ~/gits/coco-podvm-scripts/scripts/coco/podvm/provision-uptycs.sh ~/gits/coco-podvm-scripts/scripts/coco/coco-components.sh ~/gits/coco-podvm-scripts/example_run.sh'
    echo "  ✓ dm-verity DISABLED (branch: $SUBMODULE_BRANCH - files not found)"
fi

# Deploy Uptycs complete package if it exists
if [ -f edr/uptycs-complete.tar.gz ]; then
    echo "  → Deploying Uptycs complete package..."
    scp -q edr/uptycs-complete.tar.gz "$REMOTE_HOST:~/gits/coco-podvm-scripts/scripts/coco/podvm/"
    echo "  ✓ Uptycs package deployed"
else
    echo "  ⚠ Warning: edr/uptycs-complete.tar.gz not found"
    echo "  Run ./scripts/extract-all-uptycs-files.sh to create it"
fi

# Deploy .env file if it exists
if [ -f .env ]; then
    scp -q .env "$REMOTE_HOST:~/"
    echo "✓ Build script, EDR files, and credentials deployed"
else
    echo "✓ Build script and EDR files deployed (no .env file found)"
fi
echo ""

# Run the build with tag and capture output
echo "[2/3] Running build on remote host..."
echo "----------------------------------------"
BUILD_OUTPUT=$(ssh -t "$REMOTE_HOST" "PODVM_TAG=$PODVM_TAG SSHD_SERVICE=$SSHD_SERVICE APPLY_VERITY=$APPLY_VERITY ./build-podvm.sh $REMOTE_BUILD_MODE $SKIP_UPLOAD" 2>&1 | tee /dev/tty)
BUILD_STATUS=$?
echo "----------------------------------------"
echo ""

# Report results
if [ $BUILD_STATUS -eq 0 ]; then
    echo "[3/3] ✓ Build completed successfully!"
    echo ""
    
    # If qcow2-only mode, stop here
    if [ "$BUILD_MODE" = "qcow2-only" ]; then
        echo "QCOW2 build complete (skipped COS upload and VSI creation)"
        echo ""
        echo "To inspect the image on remote host:"
        echo "  ssh $REMOTE_HOST"
        echo "  ls -lh ~/.local/share/libvirt/images/rhel97-*.qcow2"
        echo ""
        echo "To continue with VSI creation later:"
        echo "  ./scripts/remote-build.sh vsi-only"
        exit 0
    fi
    
    # Extract QCOW2 filename from build output (macOS compatible)
    QCOW2_FILE=$(echo "$BUILD_OUTPUT" | grep -o 'rhel97-[0-9]*\.qcow2' | tail -1)
    
    if [ -n "$QCOW2_FILE" ]; then
        echo "QCOW2 Image: $QCOW2_FILE"
        echo ""
        echo "[4/5] Creating IBM Cloud VSI image..."
        echo "----------------------------------------"
        ./scripts/create-vsi-image.sh "$QCOW2_FILE"
        VSI_STATUS=$?
        echo "----------------------------------------"
        
        if [ $VSI_STATUS -eq 0 ]; then
            # Read the saved image ID
            IMAGE_ID_FILE="$HOME/.ibm_cloud_image_id"
            if [ -f "$IMAGE_ID_FILE" ]; then
                NEW_IMAGE_ID=$(cat "$IMAGE_ID_FILE")
                echo ""
                echo "[5/7] Configuring OpenShift..."
                echo "----------------------------------------"
                ./scripts/openshift configure-image "$NEW_IMAGE_ID" --yes
                CONFIG_STATUS=$?
                echo "----------------------------------------"
                
                if [ $CONFIG_STATUS -eq 0 ]; then
                    echo ""
                    echo "[6/7] Restarting Cloud API Adaptor..."
                    echo "----------------------------------------"
                    ./scripts/openshift restart-caa
                    echo "----------------------------------------"
                    
                    echo ""
                    echo "[7/9] Redeploying test pod..."
                    echo "----------------------------------------"
                    
                    # Delete existing test pod if it exists
                    if oc get pod test-podvm-candidate -n default &>/dev/null; then
                        echo "Deleting existing test pod..."
                        oc delete pod test-podvm-candidate -n default --wait=true --timeout=60s
                        echo "✓ Old pod deleted"
                    fi
                    
                    # Wait a moment for CAA to stabilize
                    echo "Waiting for CAA to stabilize..."
                    sleep 10
                    
                    # Deploy new test pod
                    echo "Deploying new test pod..."
                    ./scripts/openshift deploy-test
                    echo "----------------------------------------"
                    
                    echo ""
                    echo "[8/9] Running functional tests..."
                    echo "----------------------------------------"
                    if ./scripts/test-podvm.sh quick test-podvm-candidate default; then
                        echo "✓ Quick tests passed"
                        TEST_STATUS=0
                    else
                        echo "✗ Quick tests failed"
                        TEST_STATUS=1
                    fi
                    echo "----------------------------------------"
                    
                    echo ""
                    echo "[9/9] Test Summary"
                    echo "----------------------------------------"
                    if [ $TEST_STATUS -eq 0 ]; then
                        echo "=========================================="
                        echo "✓ Build, deploy, and test complete!"
                        echo "=========================================="
                        echo ""
                        echo "Test pod status:"
                        oc get pod test-podvm-candidate -n default
                        echo ""
                        echo "To run full test suite:"
                        echo "  ./scripts/test-podvm.sh all test-podvm-candidate default"
                    else
                        echo "=========================================="
                        echo "⚠️  Build complete but tests failed"
                        echo "=========================================="
                        echo ""
                        echo "Test pod status:"
                        oc get pod test-podvm-candidate -n default
                        echo ""
                        echo "To debug:"
                        echo "  ./scripts/openshift debug-pod test-podvm-candidate"
                        echo "  ./scripts/openshift debug-caa --tail 100"
                        echo ""
                        echo "To re-run tests:"
                        echo "  ./scripts/test-podvm.sh all test-podvm-candidate default"
                    fi
                else
                    echo ""
                    echo "Warning: OpenShift configuration failed"
                    echo "Skipping CAA restart and test deployment"
                fi
            else
                echo ""
                echo "Warning: Could not find saved image ID at $IMAGE_ID_FILE"
                echo "Skipping OpenShift configuration"
            fi
        fi
    else
        echo "Could not determine QCOW2 filename from build output"
    fi
else
    echo "[3/3] ✗ Build failed with exit code $BUILD_STATUS"
    echo ""
    echo "Check the output above for errors"
    exit $BUILD_STATUS
fi

# Made with Bob
