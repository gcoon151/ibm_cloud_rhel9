#!/bin/bash
# Extract all Uptycs files from container image
# This script extracts all necessary binaries and configuration files
# Supports both OpenShift (oc) and Podman

set -e

# Detect runtime: oc (OpenShift) or podman
if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    RUNTIME="oc"
    NAMESPACE="default"
    POD_NAME="uptycs-extractor"
    CONTAINER_NAME="$POD_NAME"
elif command -v podman &>/dev/null; then
    RUNTIME="podman"
    CONTAINER_NAME="uptycs-extractor"
    # Use latest Uptycs image from docs
    UPTYCS_IMAGE="us.icr.io/armada-csutil/uptycs-osquery:20260122-a7555d3b9aac00a50e4bcfb92e25eeffd57a7ad8"
else
    echo "ERROR: Neither 'oc' nor 'podman' found"
    exit 1
fi

OUTPUT_DIR="uptycs-extracted"

echo "=== Uptycs Complete File Extraction ==="
echo "Runtime: $RUNTIME"
if [ "$RUNTIME" = "oc" ]; then
    echo "Pod: $POD_NAME"
    echo "Namespace: $NAMESPACE"
else
    echo "Container: $CONTAINER_NAME"
    echo "Image: $UPTYCS_IMAGE"
fi
echo "Output: $OUTPUT_DIR"
echo ""

# Setup container based on runtime
if [ "$RUNTIME" = "oc" ]; then
    # Check if pod exists and is running
    echo "Checking pod status..."
    if ! oc get pod "$POD_NAME" -n "$NAMESPACE" &>/dev/null; then
        echo "ERROR: Pod $POD_NAME not found in namespace $NAMESPACE"
        echo "Deploy it first with: oc apply -f configs/extract-uptycs-pod.yaml"
        exit 1
    fi
    
    POD_STATUS=$(oc get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}')
    if [ "$POD_STATUS" != "Running" ]; then
        echo "ERROR: Pod is not running (status: $POD_STATUS)"
        exit 1
    fi
    
    echo "✓ Pod is running"
else
    # Podman: Start container if not running
    echo "Checking container status..."
    if ! podman ps -a --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo "Starting container from image..."
        podman run -d --name "$CONTAINER_NAME" "$UPTYCS_IMAGE" sleep infinity
        echo "✓ Container started"
    elif ! podman ps --format "{{.Names}}" | grep -q "^${CONTAINER_NAME}$"; then
        echo "Starting existing container..."
        podman start "$CONTAINER_NAME"
        echo "✓ Container started"
    else
        echo "✓ Container is running"
    fi
fi
echo ""

# Helper functions for runtime-agnostic operations
exec_cmd() {
    if [ "$RUNTIME" = "oc" ]; then
        oc exec "$POD_NAME" -n "$NAMESPACE" -- "$@"
    else
        podman exec "$CONTAINER_NAME" "$@"
    fi
}

copy_from_container() {
    local src="$1"
    local dst="$2"
    if [ "$RUNTIME" = "oc" ]; then
        oc cp "$NAMESPACE/$POD_NAME:$src" "$dst"
    else
        podman cp "$CONTAINER_NAME:$src" "$dst"
    fi
}

# Create output directories
echo "Creating output directories..."
mkdir -p "$OUTPUT_DIR/bin"
mkdir -p "$OUTPUT_DIR/etc"
mkdir -p "$OUTPUT_DIR/lib"

# List all files in /usr/bin/ to see what we're extracting
echo "Files in container /usr/bin/:"
exec_cmd ls -lh /usr/bin/
echo ""

# Extract binaries from /usr/bin/
echo "Extracting binaries from /usr/bin/..."
BINARIES=(
    "osqueryd"
    "uptycs-protect"
    "uptycs-nft"
    "bpf_progs.o"
    "uptycs_audit_conf.sh"
)

for binary in "${BINARIES[@]}"; do
    echo "  - Extracting $binary..."
    if exec_cmd test -f "/usr/bin/$binary"; then
        copy_from_container "/usr/bin/$binary" "$OUTPUT_DIR/bin/$binary"
        echo "    ✓ Extracted $(ls -lh "$OUTPUT_DIR/bin/$binary" | awk '{print $5}')"
    else
        echo "    ⚠ Not found: /usr/bin/$binary"
    fi
done

# Check for configuration files in common locations
echo ""
echo "Checking for configuration files..."

# Check /etc/uptycs/
if exec_cmd test -d "/etc/uptycs" 2>/dev/null; then
    echo "  - Found /etc/uptycs/, extracting..."
    exec_cmd find /etc/uptycs -type f 2>/dev/null | while read -r file; do
        echo "    - $file"
        rel_path="${file#/etc/uptycs/}"
        mkdir -p "$OUTPUT_DIR/etc/$(dirname "$rel_path")"
        copy_from_container "$file" "$OUTPUT_DIR/etc/$rel_path" 2>/dev/null || echo "      ⚠ Failed to extract"
    done
fi

# Check /opt/uptycs/
if exec_cmd test -d "/opt/uptycs" 2>/dev/null; then
    echo "  - Found /opt/uptycs/, listing contents..."
    exec_cmd find /opt/uptycs -type f 2>/dev/null | head -20
fi

# Check for library dependencies
echo ""
echo "Checking for library dependencies..."
if exec_cmd test -f "/usr/bin/osqueryd"; then
    echo "  - Running ldd on osqueryd..."
    exec_cmd ldd /usr/bin/osqueryd 2>/dev/null | grep "=>" | head -10
fi

# Create summary
echo ""
echo "=== Extraction Summary ==="
echo "Extracted files:"
find "$OUTPUT_DIR" -type f -exec ls -lh {} \; | awk '{print $9, $5}'
echo ""

# Calculate total size
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | awk '{print $1}')
echo "Total size: $TOTAL_SIZE"
echo ""

# Create tarball for easy transfer
echo "Creating tarball..."
TARBALL="edr/uptycs-complete.tar.gz"
tar -czf "$TARBALL" -C "$OUTPUT_DIR" .
echo "✓ Created $TARBALL ($(ls -lh "$TARBALL" | awk '{print $5}'))"
echo ""

# Update package directory
echo "Updating edr/uptycs-package/..."
mkdir -p edr/uptycs-package/bin
cp -v "$OUTPUT_DIR/bin/"* edr/uptycs-package/bin/ 2>/dev/null || true

if [ -d "$OUTPUT_DIR/etc" ]; then
    mkdir -p edr/uptycs-package/etc
    cp -rv "$OUTPUT_DIR/etc/"* edr/uptycs-package/etc/ 2>/dev/null || true
fi

echo ""
echo "=== Next Steps ==="
echo "1. Review extracted files in $OUTPUT_DIR/"
echo "2. Verify binaries are executable: file $OUTPUT_DIR/bin/*"
echo "3. Update install-uptycs.sh to include all necessary files"
echo "4. Rebuild podvm image: ./scripts/remote-build.sh qcow2 candidate"
echo ""
echo "Files ready for podvm integration!"

# Made with Bob
