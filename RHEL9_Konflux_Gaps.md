# RHEL 9 Konflux Integration Gaps

This document identifies the changes required to run RHEL 9 images through the Konflux pipeline, which currently only supports RHEL 10.

## Executive Summary

The upstream repository has migrated to RHEL 10 for its Konflux pipeline. To support RHEL 9 in Konflux, several components need to be adapted or backported. This document outlines the specific gaps and required changes.

## Current State

- **Upstream Konflux**: RHEL 10-based (main branch)
- **RHEL 9 Support**: Available in `osc-release-v1.10` branch (local scripts only, no Konflux)
- **This Fork**: RHEL 9-based with IBM Cloud customizations

## Key Differences: RHEL 9 vs RHEL 10

### 1. Kickstart File Differences

#### RHEL 9 (`helpers/rhel9-dm-root.ks`)
- Uses manual partition setup with `sfdisk` in `%pre` section
- Partition sizes: EFI (1032192 sectors), Root (5242880 sectors)
- Package list includes `kernel-uki-virt-addons`
- Simpler GRUB removal: `rpm -e grub2-efi-x64 grub2-common grub2-tools grub2-tools-minimal grubby os-prober`

#### RHEL 10 (`helpers/rhel10-dm-root.ks`)
- Uses Anaconda's automatic partitioning
- Partition sizes: EFI (512MB), Root (grows to fill disk)
- Package list includes `kernel-modules-extra` (not in RHEL 9)
- Extended GRUB removal: adds `grub2-tools-extra` to removal list
- Comments out kernel package removals (different UKI handling)
- Uses `poweroff` instead of `reboot` after install

**Gap**: Need to verify RHEL 9 kickstart works with Konflux's virt-install process.

### 2. Base Container Image

**Current (RHEL 10)**: Uses latest UBI9 base but targets RHEL 10 ISOs
**RHEL 9 Need**: Same UBI9 base, but must use RHEL 9 ISOs

**Gap**: Konflux pipeline needs to be parameterized to select correct ISO version.

### 3. Script Changes

#### `scripts/coco/coco-components.sh`

**RHEL 10 Changes**:
```bash
# Uses digest-based image references
PODVM_BINARY_DEF=quay.io/...@sha256:b14cce805fe56da2fd4bb584b786be5f6b92eda87482dd7399ef84793f202684

# Adds subscription-manager support
SM_REGISTER=(--run-command "subscription-manager register --org=${ORG_ID} --activationkey=${ACTIVATION_KEY}")

# Adds memory limit
virt-customize --memsize 8192 \

# Adds script-disk-mods.sh execution
--run $ARTIFACTS_FOLDER/script-disk-mods.sh \

# Removes cloud-init and WALinuxAgent uninstall
# (both lines removed)

# Adds subscription cleanup
[[ ${#SM_REGISTER[@]} -gt 0 ]] && virt-customize --memsize 8192 --run-command "subscription-manager unregister" -a $INPUT_IMAGE || true
```

**RHEL 9 Current**:
```bash
# Uses tag-based image references
PODVM_BINARY_DEF=quay.io/...:osc-podvm-payload-on-push-rmvjh-build-image-index

# No subscription-manager support
# No memory limit
# No script-disk-mods.sh
# Uninstalls cloud-init and WALinuxAgent
```

**Gap**: RHEL 9 version needs:
1. ✅ Subscription-manager support (useful for RHEL 9)
2. ✅ Memory limit (prevents OOM issues)
3. ✅ script-disk-mods.sh execution (if it exists)
4. ❌ Keep cloud-init uninstall removed (IBM Cloud requirement)
5. ✅ Digest-based image references (better for reproducibility)

### 4. Verity Script Changes

#### `scripts/verity/verity.sh`

**RHEL 10 Changes**:
```bash
# Dynamic verity partition sizing (7% of root instead of fixed 512MB)
verity_max_space=$((current_size * 7 / 100))

# Dynamic root partition sizing (uses actual size instead of fixed 2.5GB)
SizeMaxBytes=${current_size}

# Better EFI file selection (picks most recent if multiple exist)
UKI_NAME=$(ls -t "${efi_files[@]}" | head -1)

# Adds partprobe and udev settle after systemd-repart
partprobe $NBD_DEVICE
udevadm settle
sleep 1

# Adds debug logging
SYSTEMD_LOG_LEVEL=debug systemd-repart ...
```

**RHEL 9 Current**:
```bash
# Fixed verity partition size (512MB)
VERITY_MAX_SPACE_MB=512

# Fixed root partition size (2560MB)
SizeMaxBytes=2560M

# Simple EFI file selection (fails if multiple files)
# No partprobe/udev settle
# No debug logging
```

**Gap**: RHEL 9 version needs these improvements for reliability and flexibility.

### 5. Scratch Disk Changes

**RHEL 10**: 
- Moved from `format-scratch.sh` to `create-scratch.sh`
- Uses `systemd-repart` for scratch disk creation
- Removes `/usr/lib/repart.d/30-scratch.conf` file

**RHEL 9**:
- Uses `format-scratch.sh` with manual disk formatting
- Has `/usr/lib/repart.d/30-scratch.conf` file

**Gap**: Need to backport systemd-repart approach to RHEL 9 or verify old approach still works.

### 6. Konflux Pipeline Configuration

**Current State**: All Tekton pipelines reference RHEL 10 configurations

**Required Changes**:
1. Create RHEL 9-specific pipeline variants or parameterize existing ones
2. Update image references to use RHEL 9 ISOs
3. Update kickstart file references
4. Update component version references (osc-podvm-payload versions differ)

## Required Changes for RHEL 9 Konflux Support

### Priority 1: Critical for Functionality

1. **Create RHEL 9 Pipeline Variant**
   - Copy `.tekton/build-pipeline.yaml` to `.tekton/build-pipeline-rhel9.yaml`
   - Update ISO references to RHEL 9
   - Update kickstart file to `helpers/rhel9-dm-root.ks`
   - Update component references to RHEL 9 versions

2. **Backport Script Improvements**
   - Update `scripts/coco/coco-components.sh`:
     - Add subscription-manager support
     - Add memory limit (--memsize 8192)
     - Add script-disk-mods.sh execution
     - Use digest-based image references
     - Keep cloud-init uninstall removed (IBM Cloud)
   
3. **Backport Verity Improvements**
   - Update `scripts/verity/verity.sh`:
     - Dynamic verity partition sizing (7% instead of fixed)
     - Dynamic root partition sizing
     - Add partprobe and udev settle
     - Better EFI file selection
     - Add debug logging

### Priority 2: Important for Reliability

4. **Update Scratch Disk Handling**
   - Evaluate if systemd-repart approach works on RHEL 9
   - If yes, backport `create-scratch.sh` changes
   - If no, keep existing `format-scratch.sh` approach

5. **Kickstart Validation**
   - Test RHEL 9 kickstart with Konflux's virt-install
   - Verify partition sizes are adequate
   - Confirm UKI boot works correctly

6. **Component Version Management**
   - Create RHEL 9-specific component references
   - Set up separate osc-podvm-payload builds for RHEL 9
   - Document version differences

### Priority 3: Nice to Have

7. **Pipeline Parameterization**
   - Instead of separate pipelines, parameterize by RHEL version
   - Add `rhel-version` parameter (9 or 10)
   - Conditional logic for version-specific steps

8. **Automated Testing**
   - Create RHEL 9-specific test pipelines
   - Validate boot process
   - Verify CoCo components work correctly

9. **Documentation**
   - Document RHEL 9 vs RHEL 10 differences
   - Create RHEL 9 build instructions for Konflux
   - Update README with version-specific guidance

## Implementation Strategy

### Option A: Separate RHEL 9 Pipeline (Recommended)
**Pros**: 
- Clear separation of concerns
- Easier to maintain
- No risk of breaking RHEL 10 pipeline

**Cons**: 
- Code duplication
- Need to sync common changes

**Steps**:
1. Create `.tekton/build-pipeline-rhel9.yaml`
2. Create `konflux/Dockerfile.rhel9` if needed
3. Update all RHEL 9-specific references
4. Backport Priority 1 and 2 changes
5. Test thoroughly

### Option B: Parameterized Pipeline
**Pros**: 
- Single source of truth
- Easier to keep in sync
- More maintainable long-term

**Cons**: 
- More complex logic
- Higher risk of breaking changes
- Harder to test

**Steps**:
1. Add `rhel-version` parameter to existing pipeline
2. Add conditional steps based on version
3. Parameterize ISO and kickstart references
4. Test both versions thoroughly

## Testing Requirements

Before deploying RHEL 9 to Konflux:

1. **Local Testing**
   - Build RHEL 9 image with updated scripts
   - Verify boot process
   - Test CoCo components
   - Validate IBM Cloud compatibility

2. **Konflux Testing**
   - Test pipeline execution
   - Verify image builds successfully
   - Test image deployment
   - Validate all security features

3. **Integration Testing**
   - Test with IBM Cloud
   - Verify cloud-init functionality
   - Test confidential computing features
   - Validate attestation process

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| RHEL 9 kickstart incompatible with Konflux | High | Test locally first, have fallback plan |
| Script changes break existing functionality | Medium | Thorough testing, gradual rollout |
| Component version mismatches | Medium | Pin versions, document dependencies |
| Pipeline complexity increases | Low | Good documentation, clear separation |
| IBM Cloud-specific changes conflict | High | Maintain separate fork, document customizations |

## Estimated Effort

- **Priority 1 Changes**: 2-3 days
- **Priority 2 Changes**: 1-2 days
- **Priority 3 Changes**: 2-3 days
- **Testing**: 2-3 days
- **Documentation**: 1 day

**Total**: 8-12 days for full implementation

## Conclusion

Supporting RHEL 9 in Konflux requires:
1. Creating RHEL 9-specific pipeline configuration
2. Backporting script improvements from RHEL 10
3. Maintaining IBM Cloud-specific customizations
4. Thorough testing before deployment

The recommended approach is **Option A** (separate pipeline) for initial implementation, with potential migration to **Option B** (parameterized) once both versions are stable.

## Next Steps

1. Review this document with team
2. Decide on implementation approach (A or B)
3. Create implementation plan with timeline
4. Begin Priority 1 changes
5. Set up testing environment
6. Execute and validate