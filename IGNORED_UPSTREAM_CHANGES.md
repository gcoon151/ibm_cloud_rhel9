# Ignored Upstream Changes

This document tracks changes from the upstream `main` branch (RHEL 10) that are intentionally NOT adopted in this fork.

## Fork Strategy
- **Base Branch**: `osc-release-v1.10` (RHEL 9)
- **Upstream Main**: RHEL 10-based with Konflux integration
- **This Fork**: RHEL 9-based for IBM Cloud, without Konflux

## Reason for Divergence
The upstream repository has moved to RHEL 10 and integrated with Red Hat's Konflux CI/CD system. This fork remains on RHEL 9 for IBM Cloud compatibility and does not use Konflux.

## Categories of Ignored Changes

### 1. RHEL 10 Migration (Not Applicable)
- Kernel version bumps to RHEL 10.1
- SELinux equivalency rules for RHEL 10.1
- RHEL 10 kickstart files (`helpers/rhel10-dm-root.ks`)
- Base ISO updates to RHEL 10.1
- RHEL 10-specific configurations

**Commits**: 2e0da4c, fd0e99c, d1dc195, 715cc62, 62e075b, and related

### 2. Konflux CI/CD Integration (Not Used)
All Konflux-related changes are ignored as this fork does not use Red Hat's Konflux system:

#### Tekton Pipeline Changes
- `.tekton/build-dm-verity-image-debug.yaml` (new)
- `.tekton/build-pipeline-debug.yaml` (new)
- `.tekton/osc-dm-verity-image-debug-*.yaml` (new)
- Updates to existing `.tekton/*.yaml` files for Konflux integration
- `task/build-dm-verity-image/` updates

#### Konflux Configuration
- `konflux/Dockerfile` modifications
- `konflux/verity-definitions/` updates
- `konflux/podvm-root/` systemd service changes
- Konflux component update PRs (automated dependency updates)

#### GitHub Workflows
- `.github/workflows/validate-task-similarity.yaml` (new)

**Commits**: All PRs with "konflux/component-updates" or "konflux/references" in the branch name

### 3. Automated Dependency Updates (Konflux-Specific)
Automated PRs updating Konflux component versions:
- `chore(deps): update osc-podvm-payload to *`
- `chore(deps): update build-dm-verity-image-task to *`
- `chore(deps): update konflux references`

**Commits**: 8cff1e7, 468b987, 816a03b, b1dbf0f, 31bea66, 072d5c7, 0465739, 3a6d934, fc1e914, 42f05cb, ba96d17, ad62fa4, 4e67a44, and many more

### 4. Debug/Development Features (Optional)
- Debug pipeline configurations
- SBOM generation updates
- Task validation workflows

**Commits**: 63539ec, b335f30, c466ba2, d96be07

## Changes That MAY Be Relevant

### Potentially Useful Changes (Review Before Adopting)
These changes might be useful but need careful review for RHEL 9 compatibility:

1. **Subscription Manager Registration** (c725bf7, 62e075b)
   - Allows explicit registration using subscription-manager
   - May be useful for RHEL 9

2. **GRUB Removal Fix** (0617baa)
   - `helpers: make sure grub is removed correctly`
   - Likely applicable to RHEL 9

3. **EFI File Selection** (2c24733, 1efbbdd)
   - `verity: pick latest EFI file`
   - May be relevant for RHEL 9

4. **Scratch Disk Changes** (multiple commits)
   - Changes to `luks-scratch.service` and scratch disk creation
   - Review for RHEL 9 compatibility

5. **Azure Upload Script Updates** (azure/upload-azure.sh)
   - May contain useful improvements

6. **Version Bump to 1.11** (966de3a, 47ccddc)
   - OSC release version updates
   - Review if version alignment is needed

## Current Fork Customizations

### IBM Cloud Specific Changes
1. **Cloud-init Preservation** (commit 7caa243)
   - Removed `--uninstall cloud-init` from `scripts/coco/coco-components.sh`
   - Required for IBM Cloud functionality

## Maintenance Strategy

1. **Stay on RHEL 9**: Continue tracking `osc-release-v1.10` branch
2. **Ignore Konflux**: All Konflux-related changes are not applicable
3. **Ignore RHEL 10**: All RHEL 10-specific changes are not applicable
4. **Selective Adoption**: Review non-Konflux, non-RHEL-10 changes for potential backporting
5. **IBM Cloud Focus**: Maintain IBM Cloud-specific customizations

## Sync Status
- **Last Sync**: 2026-01-26
- **Upstream Branch**: `osc-release-v1.10` (RHEL 9)
- **Commits Behind Main**: 128 (intentionally diverged)
- **Commits Behind osc-release-v1.10**: 0 (fully synced)
- **Commits Ahead of osc-release-v1.10**: 1 (cloud-init fix)

## Notes
- The "128 commits behind" message on GitHub refers to the RHEL 10 `main` branch
- This is expected and intentional
- Focus on staying synced with `osc-release-v1.10` branch only
- Do not attempt to merge or rebase from `main` branch