# RHEL 9 Konflux Implementation - External Requirements

This document outlines the external (non-git) requirements needed to make the `rhel9-proposal` branch functional in a Konflux environment.

## Overview

The `rhel9-proposal` branch contains all the code changes necessary to support RHEL 9 in Konflux pipelines. However, several external resources and configurations are required before this can be deployed.

## Branch Summary

**Branch**: `rhel9-proposal`

**Changes Implemented**:
1. ✅ Updated `scripts/coco/coco-components.sh` with RHEL 10 improvements (subscription-manager, memory limits, digest-based images)
2. ✅ Updated `scripts/verity/verity.sh` with dynamic sizing (7% verity partition, better EFI handling)
3. ✅ Migrated scratch disk handling to systemd-repart (`create-scratch.sh`)
4. ✅ Created RHEL 9-specific Konflux Dockerfile (`konflux/Dockerfile.rhel9`)
5. ✅ Created RHEL 9 Konflux pipeline template (`.tekton/build-pipeline-rhel9.yaml`)
6. ✅ Created RHEL 9 verity definition templates
7. ✅ Preserved IBM Cloud compatibility (cloud-init not uninstalled)

## External Requirements

### 1. RHEL 9 ISO Access

**Required**: Access to RHEL 9.x installation ISO

**Details**:
- The Konflux pipeline needs a RHEL 9 ISO to build the base image
- Current upstream uses RHEL 10 ISOs
- ISO must be accessible from the Konflux build environment

**Action Items**:
- [ ] Obtain RHEL 9.x DVD ISO (latest minor version recommended)
- [ ] Upload ISO to accessible location (internal mirror, S3, etc.)
- [ ] Update pipeline parameter `rhel-iso-url` with the ISO location
- [ ] Ensure Konflux build pods have network access to ISO location

**Example**:
```yaml
params:
  - name: rhel-iso-url
    value: "https://internal-mirror.example.com/rhel-9.4-x86_64-dvd.iso"
```

### 2. RHEL 9 PodVM Payload Container Images

**Required**: RHEL 9-specific osc-podvm-payload container images

**Current State**:
- Code references: `quay.io/redhat-user-workloads/ose-osc-tenant/osc-podvm-payload-v1-10@sha256:...`
- These are RHEL 9 images but the digest is a placeholder

**Action Items**:
- [ ] Build RHEL 9-specific osc-podvm-payload containers
- [ ] Push to accessible container registry (quay.io or internal)
- [ ] Update digest references in `scripts/coco/coco-components.sh`:
  ```bash
  PODVM_BINARY_DEF=quay.io/.../osc-podvm-payload-v1-10@sha256:ACTUAL_DIGEST_HERE
  PAUSE_BUNDLE_DEF=quay.io/.../osc-podvm-payload-v1-10@sha256:ACTUAL_DIGEST_HERE
  ```
- [ ] Ensure Konflux has pull access to these images

**Note**: The `-v1-10` suffix indicates RHEL 9 version. Do not use the main branch images which are RHEL 10.

### 3. Red Hat Subscription Manager Credentials

**Required**: Activation key and Organization ID for RHEL subscription

**Purpose**:
- Register RHEL systems during build
- Install packages from Red Hat repositories
- Required for both Dockerfile and kickstart builds

**Action Items**:
- [ ] Create Red Hat activation key for automated builds
- [ ] Store credentials in Konflux secrets:
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: rhel-subscription
  type: Opaque
  data:
    org: <base64-encoded-org-id>
    activationkey: <base64-encoded-activation-key>
  ```
- [ ] Mount secret in Konflux pipeline at `/activation-key/`
- [ ] Set environment variables in pipeline:
  ```yaml
  env:
    - name: ACTIVATION_KEY
      valueFrom:
        secretKeyRef:
          name: rhel-subscription
          key: activationkey
    - name: ORG_ID
      valueFrom:
        secretKeyRef:
          name: rhel-subscription
          key: org
  ```

### 4. Konflux Task Bundle References

**Required**: Update task bundle references to actual Konflux versions

**Current State**:
- Pipeline uses placeholder task references
- Example: `quay.io/konflux-ci/tekton-catalog/task-init:0.2`

**Action Items**:
- [ ] Identify correct Konflux task bundle versions for your environment
- [ ] Update `.tekton/build-pipeline-rhel9.yaml` with actual bundle references
- [ ] Add missing tasks for:
  - Building container image (buildah or similar)
  - Running virt-install with kickstart
  - Executing verity.sh script
  - Pushing final image to registry
  - Running security scans

**Example Task Addition**:
```yaml
- name: build-container
  params:
    - name: IMAGE
      value: $(params.output-image)
    - name: DOCKERFILE
      value: $(params.dockerfile)
    - name: CONTEXT
      value: $(params.path-context)
  runAfter:
    - clone-repository
  taskRef:
    params:
      - name: name
        value: buildah
      - name: bundle
        value: quay.io/konflux-ci/tekton-catalog/task-buildah:0.1
      - name: kind
        value: task
    resolver: bundles
  workspaces:
    - name: source
      workspace: workspace
```

### 5. Container Registry Access

**Required**: Push access to container registry for built images

**Action Items**:
- [ ] Configure registry credentials in Konflux
- [ ] Create robot account or service account with push permissions
- [ ] Store credentials in Konflux secret:
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: registry-credentials
  type: kubernetes.io/dockerconfigjson
  data:
    .dockerconfigjson: <base64-encoded-docker-config>
  ```
- [ ] Link secret to pipeline service account
- [ ] Verify `output-image` parameter points to correct registry

**Example**:
```yaml
params:
  - name: output-image
    value: "quay.io/your-org/coco-podvm-rhel9:latest"
```

### 6. IBM Cloud-Specific Configuration

**Required**: Ensure cloud-init compatibility for IBM Cloud

**Current State**:
- ✅ Code already preserves cloud-init (not uninstalled)
- ✅ Only WALinuxAgent is uninstalled (Azure-specific)

**Action Items**:
- [ ] Verify cloud-init package is in RHEL 9 kickstart
- [ ] Test deployed image boots correctly in IBM Cloud
- [ ] Validate cloud-init metadata service works
- [ ] Confirm network configuration via cloud-init

**Validation**:
```bash
# On deployed VM
systemctl status cloud-init
cloud-init status
```

### 7. Secure Boot Signing (Optional but Recommended)

**Required**: Private key and certificate for signing UKI addons

**Purpose**:
- Sign verity UKI addon for secure boot
- Required for production confidential computing

**Action Items**:
- [ ] Generate or obtain secure boot signing key
- [ ] Store private key in Konflux secret:
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata:
    name: secureboot-signing
  type: Opaque
  data:
    private-key: <base64-encoded-key>
    certificate: <base64-encoded-cert>
  ```
- [ ] Mount secret in build environment
- [ ] Set environment variables:
  ```bash
  export SB_PRIVATE_KEY=/path/to/private-key
  export SB_CERTIFICATE=/path/to/certificate
  ```

**Note**: If not using secure boot, the verity.sh script will create unsigned addons.

### 8. Testing Environment

**Required**: Environment to test built images

**Action Items**:
- [ ] Set up IBM Cloud test account/project
- [ ] Configure test VM deployment automation
- [ ] Create test cases for:
  - VM boot process
  - Cloud-init functionality
  - CoCo components (kata-agent, etc.)
  - Verity verification
  - Scratch disk encryption
- [ ] Document test procedures

### 9. Monitoring and Logging

**Required**: Observability for Konflux pipeline runs

**Action Items**:
- [ ] Configure Konflux pipeline logging
- [ ] Set up alerts for build failures
- [ ] Create dashboard for build metrics
- [ ] Document troubleshooting procedures

## Implementation Checklist

### Phase 1: Prerequisites (Before Deployment)
- [ ] Obtain RHEL 9 ISO and make accessible
- [ ] Build and push RHEL 9 osc-podvm-payload images
- [ ] Configure Red Hat subscription credentials
- [ ] Set up container registry access
- [ ] Generate secure boot keys (if using)

### Phase 2: Konflux Configuration
- [ ] Create Konflux project/namespace
- [ ] Deploy all required secrets
- [ ] Update pipeline with actual task bundle references
- [ ] Configure service account permissions
- [ ] Set up pipeline triggers (if using)

### Phase 3: Testing
- [ ] Run pipeline manually with test parameters
- [ ] Verify container image builds successfully
- [ ] Deploy test VM in IBM Cloud
- [ ] Validate all functionality
- [ ] Document any issues and fixes

### Phase 4: Production Deployment
- [ ] Update production pipeline configuration
- [ ] Set up automated triggers
- [ ] Configure monitoring and alerts
- [ ] Document operational procedures
- [ ] Train team on new pipeline

## Pipeline Execution Example

Once all external requirements are met, execute the pipeline:

```bash
# Using tkn CLI
tkn pipeline start build-pipeline-rhel9 \
  --param git-url=https://github.com/gcoon151/ibm_cloud_rhel9.git \
  --param revision=rhel9-proposal \
  --param output-image=quay.io/your-org/coco-podvm-rhel9:latest \
  --param rhel-iso-url=https://mirror.example.com/rhel-9.4-x86_64-dvd.iso \
  --param kickstart-file=helpers/rhel9-dm-root.ks \
  --workspace name=workspace,claimName=pipeline-pvc \
  --showlog
```

## Troubleshooting

### Common Issues

1. **ISO Download Fails**
   - Check network connectivity from build pod
   - Verify ISO URL is accessible
   - Check for proxy/firewall issues

2. **Subscription Registration Fails**
   - Verify activation key is valid
   - Check organization ID is correct
   - Ensure secret is mounted correctly

3. **Image Digest Not Found**
   - Update digest references with actual values
   - Verify images exist in registry
   - Check pull permissions

4. **Verity Creation Fails**
   - Check systemd-repart is available
   - Verify disk has enough space
   - Review partition sizes in kickstart

5. **Cloud-init Not Working**
   - Verify cloud-init package is installed
   - Check systemd service is enabled
   - Review cloud-init logs in VM

## Support and Documentation

- **Gap Analysis**: See `RHEL9_Konflux_Gaps.md` for detailed technical analysis
- **Ignored Changes**: See `IGNORED_UPSTREAM_CHANGES.md` for upstream divergence
- **Upstream Docs**: https://github.com/confidential-devhub/coco-podvm-scripts
- **Konflux Docs**: https://konflux-ci.dev/docs/

## Success Criteria

The implementation is successful when:
- ✅ Pipeline runs without errors
- ✅ RHEL 9 image builds successfully
- ✅ Image boots in IBM Cloud
- ✅ Cloud-init configures VM correctly
- ✅ CoCo components function properly
- ✅ Verity verification passes
- ✅ Scratch disk encryption works
- ✅ All security scans pass

## Next Steps After Implementation

1. **Automation**: Set up automated builds on git push
2. **Versioning**: Implement semantic versioning for images
3. **Documentation**: Create runbooks for operations team
4. **Optimization**: Profile build times and optimize
5. **Maintenance**: Plan for RHEL 9 updates and patches

## Contact

For questions or issues with this implementation:
- Review the gap analysis document
- Check Konflux documentation
- Consult with Red Hat support for subscription issues
- Test in non-production environment first

---

**Last Updated**: 2026-01-26
**Branch**: rhel9-proposal
**Status**: Ready for external configuration