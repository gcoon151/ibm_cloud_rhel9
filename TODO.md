# TODO - Build System Improvements

## Completed (June 5, 2026)

### ✅ Fixed agent-config.toml missing configuration
**Issue**: Red Hat's payload container only included 2 lines in agent-config.toml, missing `image_registry_auth` line.

**Solution**: Added patch in `scripts/coco/podvm/podvm_maker.sh` to append missing line during build.

**Result**: 
- Built and validated image rhel97-2026060405.qcow2
- All 15 tests passed
- Added to working_list.txt

---

### ✅ Implemented hardened image workflow
**Issue**: Need SSH-disabled images for production/compliance requirements.

**Solution**: 
- Created `scripts/harden-image.sh` to create hardened versions from validated images
- Fixed `scripts/create-vsi-image.sh` to detect and handle hardened images
- Added hardened test suite (7 tests, no SSH required)
- Documented complete workflow in BUILD_ARCHITECTURE.md

**Result**:
- Built and validated rhel97-2026060405-hardened.qcow2
- All 7 hardened tests passed
- Added to working_list.txt

---

## High Priority

### 0. UPSTREAM FIX NEEDED: peer-pods-webhook failurePolicy causes cluster networking deadlock
**Issue**: The OSC `peer-pods-webhook` mutating admission webhook uses `failurePolicy: Fail`
and no namespace/object selector to exclude CNI system namespaces. This creates a
circular deadlock after worker node replacement: calico-node pods can't be created
because the webhook is unreachable, and the webhook is unreachable because calico-node
hasn't started yet.

**Impact**: Every worker node replacement or cluster restart with OSC installed risks
all nodes becoming permanently `NotReady` until manual intervention.

**Workaround** (documented in `docs/CLUSTER_NETWORKING_DEADLOCK.md`):
```bash
oc patch mutatingwebhookconfiguration mutating-webhook-configuration \
  --type='json' -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
oc rollout restart daemonset/calico-node -n calico-system
# restore after nodes are Ready:
oc patch mutatingwebhookconfiguration mutating-webhook-configuration \
  --type='json' -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Fail"}]'
```

**Upstream fix**: The webhook should either:
1. Use `failurePolicy: Ignore` (simplest — the webhook only annotates, doesn't gate)
2. Add `namespaceSelector` to exclude `calico-system`, `openshift-ovn-kubernetes`, etc.
3. Add `objectSelector` scoped to pods requesting `kata.peerpods.io/vm` resource

**Tasks**:
- [ ] File issue against `openshift-sandboxed-containers-operator` upstream
- [ ] Submit PR changing `failurePolicy` to `Ignore` with justification
- [ ] Reference `docs/CLUSTER_NETWORKING_DEADLOCK.md` in the issue

**Priority**: High - silent cluster-breaking failure on every worker rotation

---

### 1. RHEL 9.8 Base Image for CVE Fixes
**Goal**: Update base image to RHEL 9.8 to pull in critical CVE fixes.

**Tasks**:
- [ ] Download RHEL 9.8 ISO from Red Hat
- [ ] Review kickstart file (helpers/rhel9-dm-root.ks) for any needed updates
- [ ] Build new base image from RHEL 9.8 ISO
- [ ] Test with existing payload (ffb785e)
- [ ] Validate boot and functionality
- [ ] Document any changes needed for RHEL 9.8

**Priority**: High - security updates

---

### 2. Image Signing for Hardened Images
**Goal**: Implement container image signature verification in hardened images.

**Background**: 
- agent-config.toml has `enable_signature_verification = true` and `image_policy_file = "/etc/containers/policy.json"`
- Currently these settings are present but not fully functional
- Need proper policy.json configuration

**Tasks**:
- [ ] Research proper policy.json format for signature verification
- [ ] Create working policy.json with all required fields
- [ ] Test signature verification with signed images
- [ ] Add signature verification to hardened build workflow
- [ ] Document signing process and requirements
- [ ] Update BUILD_ARCHITECTURE.md with signing workflow

**Priority**: High - security requirement for hardened images

**Note**: DO NOT add signature verification lines to agent-config.toml without a working policy.json!

---

### 3. INVESTIGATE: Can kernel update move back to kickstart now that repos are synced?
**Question**: Now that build host (192.168.1.196) and orchestration host (Mac) are on the same repo/branch, can we move the kernel update back into the kickstart file?

**Background**:
- Previously had kernel update in kickstart (lines 101-103 in rhel9-dm-root.ks)
- Removed it and moved to optional `update-kernel.sh` script
- Build host was potentially on different branch/repo when kickstart was failing
- Now both hosts are synchronized on main branch

**Testing Required**:
- [ ] Verify build host and Mac are on same branch/commit
- [ ] Test kernel update in kickstart with synchronized repos
- [ ] If successful, can simplify by removing `update-kernel.sh` and `UPDATE_KERNEL` flag
- [ ] Document whether repo synchronization was the root cause

**Priority**: Medium - would simplify build process if kernel update can be in kickstart

---

### 4. RESOLVED: Commit 26a408e investigation
**Status**: Issue was resolved by agent-config.toml fix. The missing `image_registry_auth` line was causing boot failures, not the kernel removal changes.

**Conclusion**: Kernel removal in kickstart is safe and working. The May 6 failure was due to missing agent-config.toml configuration, not kernel removal.

---

## Medium Priority

### 1. Improve Uptycs tarball handling
**Issue**: Uptycs tarballs (`scripts/coco/podvm/uptycs-*.tar.gz`) are currently NOT in `.gitignore` to allow container builds to work. This means large binary files (19MB) could be committed to git.

**Current workaround**: Removed from `.gitignore` temporarily

**Desired solution**: 
- Use `.dockerignore` to explicitly include Uptycs files for container builds
- Keep them in `.gitignore` to prevent accidental commits
- OR: Download Uptycs from a secure location during build instead of copying from local files

**Priority**: Medium - prevents large binaries in git history

---

### 2. Automate Red Hat upstream image tag updates
**Issue**: Currently pinned to `ffb785e` tag in scripts. Need to automate checking for and updating to latest Red Hat upstream image.

**Current state**:
- Hardcoded `ffb785e` in `scripts/remote-build.sh` default
- Hardcoded `ffb785e` in `ibm_cloud_rhel9/build/build-podvm.sh` default
- Manual process to find and update to new tags

**Desired solution**:
- Script to query Red Hat registry for latest tag
- Automated update of default tag in scripts
- Documentation on how to find latest tag manually
- Consider using `latest` tag if Red Hat provides one

**Priority**: Medium - improves maintainability

---

### 3. Optimize container rebuild strategy
**Issue**: Currently using `--no-cache` for all container builds, which is slow

**Desired solution**:
- Only rebuild when Uptycs files change
- Use build cache for dependency layers
- Add checksum-based rebuild detection

**Priority**: Medium - improves build speed

---

## Low Priority

### 1. Add automated testing
- Test that Uptycs binaries are in built images
- Test that dm-verity is working
- Test that images boot successfully

### 2. Improve error messages
- Better diagnostics when builds fail
- Clear indication of which step failed
- Suggestions for common issues

### 3. Intercept kickstart build logs better
- Improve log capture during base image build
- Better error reporting from kickstart process

---

## Notes

### Latest Validated Images (June 5, 2026)
- **Standard**: rhel97-2026060405.qcow2 (VSI: r014-39f02efb-aabf-4784-9097-dfd7dc2477d4)
- **Hardened**: rhel97-2026060405-hardened.qcow2 (VSI: r014-cb24353c-17a4-4360-9bb5-c2347c9ef9d7)
- Both in working_list.txt with changelog (CHANGELOG_2026060405.md)

### Current Uptycs Version
- Version: 5.18.1.18-Uptycs-Protect (20260122)
- Image: `us.icr.io/armada-csutil/uptycs-osquery:20260122-a7555d3b9aac00a50e4bcfb92e25eeffd57a7ad8`
- Find latest: `cat ~/Bob-Work/ArmadaCSutil/Changelogs/prod/CHANGE_LOGS.json | grep "uptycs-osquery" | head -1`
