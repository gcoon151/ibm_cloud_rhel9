# Ignored Upstream Changes

This document tracks changes from the upstream `main` branch that are intentionally NOT adopted in this fork.

## Upstream Repository Structure

See `upstream-repos/README.md` for details on the full OpenShift confidential containers ecosystem.

**Key Repositories:**
- **coco-podvm-scripts** (this fork): DM-verity image building
- **cloud-api-adaptor**: PodVM payload binaries (agent-protocol-forwarder, kata-agent, etc.)
- **sandboxed-containers-operator**: Operator and bundle
- **kata-containers**: Monitor
- **confidential-compute-artifacts**: Storage helper, TDX components

## Fork Strategy
- **Base Branch**: `osc-release-v1.10` (RHEL 9)
- **Upstream Main**: RHEL 10-based with Konflux integration
- **This Fork**: RHEL 9-based for IBM Cloud, without Konflux

## Reason for Divergence
The upstream repository has moved to RHEL 10 and integrated with Red Hat's Konflux CI/CD system. This fork remains on RHEL 9 for IBM Cloud compatibility and does not use Konflux.

## Categories of Ignored Changes

### 1. RHEL 10 Migration (Not Applicable)
All RHEL 10-specific changes are ignored as this fork remains on RHEL 9:

- Kernel version bumps to RHEL 10.1 (2e0da4c, c466ba2)
- SELinux equivalency rules for RHEL 10.1 (fd0e99c, 715cc62)
- RHEL 10 kickstart files (`helpers/rhel10-dm-root.ks`)
- Base ISO updates to RHEL 10.0/10.1 (4673821, d1dc195)
- RHEL 10-specific configurations
- GRUB removal fixes for RHEL 10 (0617baa - only applies to rhel10-dm-root.ks)
- Root password removal for RHEL 10 (246463e)
- Default payload updates to 1.11.1 (2668273)

**Rationale**: This fork targets RHEL 9 for IBM Cloud compatibility. RHEL 10 changes are not applicable.

### 2. Konflux CI/CD Integration (Not Used)
All Konflux-related changes are ignored as this fork does not use Red Hat's Konflux system:

#### Automated Dependency Updates (~50 commits - Ignored)
Automated PRs updating Konflux-specific components:
- `chore(deps): update build-dm-verity-image-task to *` (18+ commits) - Konflux task updates
- `chore(deps): update konflux references` (multiple commits) - Konflux pipeline references
- `chore(deps): update registry.redhat.io/ubi9/ubi-init docker digest` (multiple commits) - Base image updates

#### Konflux Configuration Changes (~28 commits)
- `konflux/Dockerfile` modifications (44 file changes)
- `konflux/verity-definitions/` updates
- `konflux/podvm-root/` systemd service changes
- `.tekton/` pipeline files (new and updated)
- `task/build-dm-verity-image/0.1/build-dm-verity-image.yaml` updates (18 changes)

#### Konflux-Specific Features
- Debug pipeline configurations (a9e1ea9, 8b38249)
- Task validation workflows (43748a8)
- SBOM generation updates (b335f30, 63539ec)
- Deprecated task replacements (b335f30)
- CPE label fixes for Konflux (7712023)
- Build-image-index reference updates (7328da2)
- Prefetch task parameter removal (19d1efd)
- PODVM_PAYLOAD_IMAGE parameter removal (bdfa74c, d132239)

**Rationale**: This fork uses a custom build pipeline on IBM Cloud, not Konflux.

### 3. Version Bumps (Konflux-Specific)
- OSC release version 1.11 (47ccddc, 966de3a)
- OSC release version 1.12 (bff2017, 1f71ae1)
- Resource request increases (d144f59)

**Rationale**: Version numbers are tied to Konflux releases and don't apply to this fork's versioning scheme.

### 4. Task/Pipeline Refactoring (Konflux-Specific)
Script refactoring for Konflux task system:
- Extract virt-customize logic (b5a08d5)
- Rename script-podvm-maker.sh to podvm-setup.sh (274c92c)
- Pass disk/output paths as arguments (9896391, 3898379)
- Make script-push.sh receive arguments (5843bfa)
- Task documentation (1aa2ec8)

**Rationale**: These changes support Konflux's task-based build system, not applicable to local builds.

## Changes That MAY Be Relevant

### Potentially Useful Changes (Review Before Adopting)
These changes might be useful but need careful review for RHEL 9 compatibility:

1. **Payload Binary Updates** (~44 commits) ⚠️ HIGH PRIORITY
   - `chore(deps): update osc-podvm-payload to *` (44+ commits)
   - Updates to peer pod runtime binaries from https://github.com/openshift/cloud-api-adaptor
   - **Contains**: agent-protocol-forwarder, kata-agent, pause, and other peer pod binaries
   - **Also Contains**: Configuration files like `/etc/agent-config.toml`, `/etc/containers/policy.json`
   - **Status**: REVIEW RECOMMENDED - May contain bug fixes, security updates, and improvements
   - **Action**: Check cloud-api-adaptor changelog/releases for relevant fixes before updating
   - **Critical Example**: agent-config.toml was added to cloud-api-adaptor in March 2024 (commit 3aeb1c9d)
     - Signature verification settings were removed in June 2024 (commit 8e73469a)
     - Our fork re-added these for IBM Cloud security requirements
   - **Note**: These are the actual runtime binaries and configs used in peer pods, not just build infrastructure
   - **See**: `upstream-repos/cloud-api-adaptor` for detailed history

2. **Subscription Manager Registration** (c725bf7, 62e075b)
   - Allows explicit registration using subscription-manager
   - **Status**: May be useful for RHEL 9, needs testing
   - **Files**: Kickstart files

2. **EFI File Selection** (1efbbdd, 2c24733)
   - `verity: pick latest EFI file`
   - Ensures `/boot/efi/EFI/redhat/BOOTX64.CSV` points to correct file
   - **Status**: Likely applicable to RHEL 9
   - **Files**: `scripts/verity/verity.sh`

3. **LUKS Scratch Disk Improvements** (b0e738b, 6c10f55)
   - Use systemd-repart for LUKS encryption (performance improvement)
   - Ensure LUKS partition is opened correctly
   - **Status**: Review for RHEL 9 compatibility
   - **Files**: `scripts/coco/podvm/luks-scratch/*`

4. **Verity Partition Calculation Fix** (c3db762, 980c6bc)
   - Fixes verity partition size calculation
   - **Status**: May be relevant if using dm-verity
   - **Files**: `konflux/verity-definitions/*`, task files

5. **Azure Upload Script Improvements** (839ecaf, d4c3c9c)
   - Create raw/vhd disks next to qcow2 (space optimization)
   - Remove useless function call
   - **Status**: Useful if using Azure
   - **Files**: `azure/upload-azure.sh`

6. **Image Digest Fix** (323df7e, d96be07)
   - Don't append newline to image digest result
   - **Status**: Minor fix, may be useful
   - **Files**: Debug/task scripts

7. **Kickstart Comment Update** (17b6c62)
   - Update ks execution comment
   - **Status**: Documentation only
   - **Files**: `helpers/rhel10-dm-root.ks` (RHEL 10 only)

## Current Fork Customizations

### IBM Cloud Specific Changes
1. **Cloud-init Preservation** (commit 7caa243)
   - Removed `--uninstall cloud-init` from `scripts/coco/coco-components.sh`
   - Required for IBM Cloud functionality

2. **Uptycs EDR Integration**
   - Custom scripts for Uptycs agent installation
   - Systemd service configurations
   - Not present in upstream

3. **IBM Cloud Build Pipeline**
   - Custom build scripts in `build/` directory
   - IBM Cloud Object Storage integration
   - VSI image creation automation

## Maintenance Strategy

1. **Stay on RHEL 9**: Continue tracking `osc-release-v1.10` branch
2. **Ignore Konflux**: All Konflux-related changes (~122 commits) are not applicable
3. **Ignore RHEL 10**: All RHEL 10-specific changes (~6 commits) are not applicable
4. **Ignore Automated Updates**: All dependency update commits (~94 commits) are not applicable
5. **Selective Adoption**: Review non-Konflux, non-RHEL-10 changes for potential backporting
6. **IBM Cloud Focus**: Maintain IBM Cloud-specific customizations

## Sync Status
- **Last Review**: 2026-06-18
- **Upstream Branch Reviewed**: `main` (RHEL 10 + Konflux)
- **Commits Behind Main**: 244 (intentionally diverged)
  - ~122 Konflux-related commits
  - ~94 Automated dependency updates
  - ~6 RHEL 10-specific commits
  - ~22 Other changes (mostly task refactoring, version bumps, debug features)
- **Commits Behind osc-release-v1.10**: Unknown (need to check)
- **Commits Ahead of osc-release-v1.10**: 1+ (cloud-init fix + custom features)

## Summary Statistics
Out of 244 commits behind upstream/main:
- **Ignored (Konflux)**: ~122 commits (50%)
- **Ignored (Dependencies)**: ~50 commits (20.5%) - Build infrastructure only
- **Ignored (RHEL 10)**: ~6 commits (2.5%)
- **Ignored (Other)**: ~15 commits (6%) - version bumps, task refactoring
- **Potentially Relevant**: ~51 commits (21%) - see "Changes That MAY Be Relevant" section
  - ~44 commits: Payload binary updates (peer pod runtime)
  - ~7 commits: Other improvements (EFI, LUKS, verity, etc.)

## Notes
- The "244 commits behind" message on GitHub refers to the RHEL 10 `main` branch
- This is expected and intentional
- ~79% of upstream changes are not applicable to this fork (Konflux, RHEL 10, build infrastructure)
- ~21% are potentially relevant (primarily payload binary updates)
- **Important**: The 44 payload binary updates should be reviewed as they contain peer pod runtime improvements
- Focus on staying synced with `osc-release-v1.10` branch only
- Do not attempt to merge or rebase from `main` branch
- Review the "Potentially Relevant" section periodically for useful backports