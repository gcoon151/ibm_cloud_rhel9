# PodVM Payload Builder

This directory contains everything needed to build the PodVM payload container image that includes all CoCo (Confidential Containers) components.

## Overview

The PodVM payload contains:
- **kata-agent**: The agent running inside the PodVM
- **attestation-agent**: Handles attestation for confidential computing
- **pause-bundle**: Minimal pause container for Kubernetes
- Other CoCo components

This payload is built from the [cloud-api-adaptor](https://github.com/openshift/cloud-api-adaptor) repository and pushed to IBM Cloud Container Registry (ICR).

## Architecture

```
cloud-api-adaptor (submodule)
    ├── podvm-payload/
    │   ├── Dockerfile (patched for subscription-manager)
    │   ├── kata-containers/ (submodule)
    │   └── guest-components/ (submodule)
    └── ...

build-payload.sh → Builds → Pushes to ICR → Used by coco-components.sh
```

## Prerequisites

### 1. Red Hat Subscription

You need a Red Hat subscription to build the payload (for RHEL packages).

Create two files:
- `org.txt`: Contains your Red Hat Organization ID
- `key.txt`: Contains your Red Hat Activation Key

```bash
echo "YOUR_ORG_ID" > org.txt
echo "YOUR_ACTIVATION_KEY" > key.txt
```

### 2. Build Tool

Install either Podman or Docker:

```bash
# Podman (recommended)
dnf install -y podman

# Or Docker
dnf install -y docker
```

### 3. IBM Cloud CLI (for pushing to ICR)

```bash
# Install IBM Cloud CLI
curl -fsSL https://clis.cloud.ibm.com/install/linux | sh

# Login
ibmcloud login --sso

# Target region
ibmcloud target -r us-south
```

### 4. Git Submodules

The cloud-api-adaptor repository is included as a submodule:

```bash
# Initialize submodules (if not already done)
git submodule update --init --recursive
```

## Quick Start

### Basic Build and Push

```bash
# Build and push to IBM Cloud Container Registry
./build-payload.sh \
  --org-file org.txt \
  --key-file key.txt \
  --registry us.icr.io \
  --namespace my-namespace
```

### Build Only (No Push)

```bash
# Build locally without pushing
./build-payload.sh \
  --org-file org.txt \
  --key-file key.txt \
  --no-push
```

### Custom Version

```bash
# Build specific version
./build-payload.sh \
  --version 1.10.4 \
  --org-file org.txt \
  --key-file key.txt \
  --registry us.icr.io \
  --namespace my-namespace
```

## Configuration Options

### Command Line Options

```
-h, --help              Show help message
-v, --version VERSION   Payload version (default: 1.10.3)
-a, --arch ARCH         Architecture: x86_64, aarch64, s390x (default: x86_64)
-r, --registry REGISTRY Registry URL (default: us.icr.io)
-n, --namespace NS      Registry namespace (required for ICR)
-i, --image NAME        Image name (default: podvm-payload)
-o, --org-file FILE     Red Hat org ID file (required)
-k, --key-file FILE     Red Hat activation key file (required)
-t, --tool TOOL         Build tool: podman or docker (default: podman)
--no-push               Build only, don't push to registry
--cleanup               Remove local image after push
```

### Environment Variables

```bash
export PAYLOAD_VERSION="1.10.3"
export ARCH="x86_64"
export REGISTRY="us.icr.io"
export NAMESPACE="my-namespace"
export IMAGE_NAME="podvm-payload"
export RHEL_ORG_FILE="org.txt"
export RHEL_KEY_FILE="key.txt"
export BUILD_TOOL="podman"
```

## IBM Cloud Container Registry Setup

### 1. Create Namespace

```bash
# Login to IBM Cloud
ibmcloud login --sso

# Target region
ibmcloud target -r us-south

# Create namespace
ibmcloud cr namespace-add my-namespace
```

### 2. Login to ICR

```bash
# Login to container registry
ibmcloud cr login
```

### 3. Verify Access

```bash
# List namespaces
ibmcloud cr namespace-list

# List images
ibmcloud cr image-list --restrict my-namespace
```

## Build Process

The build script performs these steps:

1. **Check Prerequisites**
   - Verify build tool (podman/docker)
   - Check git and submodules
   - Validate subscription files
   - Check IBM Cloud CLI (if pushing to ICR)

2. **Apply Dockerfile Patch**
   - Patches the Dockerfile to use build secrets for subscription-manager
   - Enables additional attestation features (snp-attester, tdx-attester)

3. **Build Payload Image**
   - Runs podman/docker build with subscription secrets
   - Builds for specified architecture
   - Includes all CoCo components

4. **Verify Image**
   - Checks image exists locally
   - Extracts and saves image digest
   - Reports image size

5. **Push to Registry** (if not --no-push)
   - Logs in to ICR
   - Creates namespace if needed
   - Pushes image

6. **Generate Usage Info**
   - Creates `payload-info.txt` with usage instructions
   - Includes image digest and pull commands

## Output Files

After a successful build, you'll find:

### payload-info.txt

Contains usage information:
```
PodVM Payload Build Information
================================

Image Tag: us.icr.io/my-namespace/podvm-payload:1.10.3
Image Digest: sha256:abc123...
Full Reference: us.icr.io/my-namespace/podvm-payload@sha256:abc123...

Usage in coco-components.sh:
----------------------------
PODVM_BINARY_DEF="us.icr.io/my-namespace/podvm-payload@sha256:abc123..."
PAUSE_BUNDLE_DEF="us.icr.io/my-namespace/podvm-payload@sha256:abc123..."
```

### payload-digest.txt

Contains just the image digest for automation:
```
sha256:abc123...
```

## Using the Payload

### In coco-components.sh

Update the image references in `scripts/coco/coco-components.sh`:

```bash
# Use digest-based reference (recommended)
PODVM_BINARY_DEF="us.icr.io/my-namespace/podvm-payload@sha256:abc123..."
PAUSE_BUNDLE_DEF="us.icr.io/my-namespace/podvm-payload@sha256:abc123..."

# Or use tag-based reference
PODVM_BINARY_DEF="us.icr.io/my-namespace/podvm-payload:1.10.3"
PAUSE_BUNDLE_DEF="us.icr.io/my-namespace/podvm-payload:1.10.3"
```

### Verify Payload Contents

```bash
# List files in payload
podman run --rm us.icr.io/my-namespace/podvm-payload:1.10.3 ls -la /artifacts/

# Expected output:
# /artifacts/usr/local/bin/kata-agent
# /artifacts/usr/local/bin/attestation-agent
# /artifacts/pause-bundle.tar.gz
# /artifacts/podvm-binaries.tar.gz
```

## Dockerfile Patch Details

The patch makes two key changes:

### 1. Subscription Manager with Build Secrets

**Before:**
```dockerfile
#RUN if command -v subscription-manager; then \
#      subscription-manager register --org "$(cat /activation-key/org)" ...
```

**After:**
```dockerfile
RUN --mount=type=secret,id=org,dst=/run/secrets/org \
    --mount=type=secret,id=key,dst=/run/secrets/key \
    if command -v subscription-manager; then \
      subscription-manager register --org "$(cat /run/secrets/org)" ...
```

This uses Docker/Podman build secrets instead of requiring files in the build context.

### 2. Additional Attestation Features

**Before:**
```dockerfile
cargo build --features "coco_as,kbs,az-snp-vtpm-attester,az-tdx-vtpm-attester,..."
```

**After:**
```dockerfile
cargo build --features "coco_as,kbs,az-snp-vtpm-attester,az-tdx-vtpm-attester,snp-attester,tdx-attester,..."
```

Adds direct SNP and TDX attesters (not just vTPM-based).

## Troubleshooting

### Build Fails with Subscription Error

```
Error: subscription-manager register failed
```

**Solution**: Verify your org.txt and key.txt files contain correct credentials.

```bash
# Test credentials
subscription-manager register --org "$(cat org.txt)" --activationkey "$(cat key.txt)"
```

### Push Fails to ICR

```
Error: unauthorized: authentication required
```

**Solution**: Login to IBM Cloud and ICR:

```bash
ibmcloud login --sso
ibmcloud cr login
```

### Namespace Not Found

```
Error: namespace not found
```

**Solution**: Create the namespace:

```bash
ibmcloud cr namespace-add my-namespace
```

### Submodule Not Initialized

```
Error: cloud-api-adaptor submodule not initialized
```

**Solution**: Initialize submodules:

```bash
git submodule update --init --recursive
```

### Build Takes Too Long

The first build can take 30-60 minutes due to:
- Downloading Rust toolchain
- Compiling guest-components
- Compiling kata-agent

Subsequent builds are faster due to layer caching.

## Advanced Usage

### Building for Multiple Architectures

```bash
# Build for x86_64
./build-payload.sh --arch x86_64 --org-file org.txt --key-file key.txt

# Build for aarch64
./build-payload.sh --arch aarch64 --org-file org.txt --key-file key.txt

# Build for s390x
./build-payload.sh --arch s390x --org-file org.txt --key-file key.txt
```

### Using with Different Registries

```bash
# Quay.io
./build-payload.sh \
  --registry quay.io \
  --namespace my-org \
  --org-file org.txt \
  --key-file key.txt

# Docker Hub
./build-payload.sh \
  --registry docker.io \
  --namespace my-username \
  --org-file org.txt \
  --key-file key.txt
```

### Automation / CI/CD

```bash
#!/bin/bash
# Example CI/CD script

# Set credentials from environment
echo "$RHEL_ORG_ID" > /tmp/org.txt
echo "$RHEL_ACTIVATION_KEY" > /tmp/key.txt

# Build and push
./build-payload.sh \
  --org-file /tmp/org.txt \
  --key-file /tmp/key.txt \
  --registry us.icr.io \
  --namespace production \
  --version "$(git describe --tags)" \
  --cleanup

# Clean up credentials
rm -f /tmp/org.txt /tmp/key.txt
```

## Version Management

### Semantic Versioning

Follow the cloud-api-adaptor versioning:
- `1.10.x` - RHEL 9 based (osc-release-v1.10 branch)
- `1.11.x` - Future releases

### Tagging Strategy

```bash
# Production release
./build-payload.sh --version 1.10.3 ...

# Development build
./build-payload.sh --version 1.10.3-dev ...

# Feature branch
./build-payload.sh --version 1.10.3-feature-xyz ...
```

## Security Considerations

### Subscription Credentials

- **Never commit** org.txt or key.txt to git
- Use `.gitignore` to exclude these files
- In CI/CD, use secret management (GitHub Secrets, etc.)
- Rotate activation keys regularly

### Image Signing

Consider signing images for production:

```bash
# Sign with cosign
cosign sign us.icr.io/my-namespace/podvm-payload:1.10.3

# Verify signature
cosign verify us.icr.io/my-namespace/podvm-payload:1.10.3
```

### Vulnerability Scanning

Scan images before deployment:

```bash
# Using IBM Cloud Vulnerability Advisor
ibmcloud cr vulnerability-assessment us.icr.io/my-namespace/podvm-payload:1.10.3

# Using Trivy
trivy image us.icr.io/my-namespace/podvm-payload:1.10.3
```

## Maintenance

### Updating cloud-api-adaptor

```bash
# Update submodule to latest osc-release-v1.10
cd payload-builder/cloud-api-adaptor
git fetch origin
git checkout origin/osc-release-v1.10
git submodule update --init --recursive
cd ../..

# Commit the update
git add payload-builder/cloud-api-adaptor
git commit -m "Update cloud-api-adaptor to latest osc-release-v1.10"
```

### Rebuilding After Updates

```bash
# Rebuild with updated submodule
./build-payload.sh \
  --org-file org.txt \
  --key-file key.txt \
  --registry us.icr.io \
  --namespace my-namespace
```

## References

- [cloud-api-adaptor Repository](https://github.com/openshift/cloud-api-adaptor)
- [Confidential Containers Documentation](https://confidentialcontainers.org/)
- [IBM Cloud Container Registry](https://cloud.ibm.com/docs/Registry)
- [Red Hat Subscription Management](https://access.redhat.com/management)

## Support

For issues:
1. Check troubleshooting section above
2. Verify prerequisites are met
3. Review build logs
4. Check cloud-api-adaptor repository for known issues