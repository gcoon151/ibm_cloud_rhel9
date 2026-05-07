# TODO - Build System Improvements

## High Priority

### 1. INVESTIGATE: Can kernel update move back to kickstart now that repos are synced?
**Question**: Now that build host (192.168.1.196) and orchestration host (Mac) are on the same repo/branch, can we move the kernel update back into the kickstart file?

**Background**:
- Previously had kernel update in kickstart (lines 101-103 in rhel9-dm-root.ks)
- Removed it and moved to optional `update-kernel.sh` script
- Build host was potentially on different branch/repo when kickstart was failing
- Now both hosts are synchronized on `feature/consolidate-build-system` branch

**Testing Required**:
- [ ] Verify build host and Mac are on same branch/commit
- [ ] Test kernel update in kickstart with synchronized repos
- [ ] If successful, can simplify by removing `update-kernel.sh` and `UPDATE_KERNEL` flag
- [ ] Document whether repo synchronization was the root cause

**Priority**: Medium - would simplify build process if kernel update can be in kickstart

---

### 2. URGENT: Investigate commit 26a408e changes that broke agent-protocol-forwarder
**Issue**: Commit 26a408e (May 6, 08:21) broke peer pod boot. The commit message says "Remove kernel removal code" but that's BACKWARDS - the working image (May 5) HAD kernel removal, the broken image (May 6) did NOT.

**Root Cause Analysis Needed**:
Commit 26a408e made these changes to `helpers/rhel9-dm-root.ks`:

1. **REMOVED kernel removal code** (lines 104-110):
   ```bash
   OLD_KERNELS=$(rpm -q kernel-uki-virt | head -n -1)
   if [ -n "$OLD_KERNELS" ]; then
       OLD_VERSION=$(echo $OLD_KERNELS | sed 's/kernel-uki-virt-//')
       dnf remove -y kernel-uki-virt-$OLD_VERSION kernel-modules-core-$OLD_VERSION
   fi
   ```

2. **ADDED extra log cleanup**:
   ```bash
   rm -f /var/log/rhsm/*
   ```

3. **ADDED partition GUID fix**:
   ```bash
   sfdisk --part-type /dev/sda 2 4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
   ```

4. **ADDED UKI install speedup**:
   ```bash
   touch /etc/kernel/install.d/20-grub.install
   touch /etc/kernel/install.d/50-dracut.install
   ```

**Testing Required**:
- [ ] Revert commit 26a408e completely (restore kernel removal)
- [ ] Test if image works
- [ ] If it works, add back changes ONE AT A TIME:
  - [ ] Test with just `rm -f /var/log/rhsm/*`
  - [ ] Test with just `sfdisk --part-type` change
  - [ ] Test with just `touch /etc/kernel/install.d/*` changes
- [ ] Identify which specific change breaks agent-protocol-forwarder

**Current Status**:
- Reverted to working base image (May 5) on remote host
- Ready to rebuild and test
- Need to systematically test each change

**Priority**: CRITICAL - blocking all new builds

---

### 2. Implement safe kernel removal (DEPRIORITIZED - see item 1)
**Issue**: Need to understand if kernel removal actually breaks things or if it was another change in commit 26a408e.

**Current state**:
- Kickstart updates kernel to fix CVE-2026-31431
- Working image (May 5) HAD kernel removal and worked fine
- Broken image (May 6) did NOT have kernel removal but was broken

**This suggests kernel removal is NOT the problem!**

**Priority**: Medium - blocked by item 1

---

### 2. Improve Uptycs tarball handling
**Issue**: Uptycs tarballs (`scripts/coco/podvm/uptycs-*.tar.gz`) are currently NOT in `.gitignore` to allow container builds to work. This means large binary files (19MB) could be committed to git.

**Current workaround**: Removed from `.gitignore` temporarily

**Desired solution**: 
- Use `.dockerignore` to explicitly include Uptycs files for container builds
- Keep them in `.gitignore` to prevent accidental commits
- OR: Download Uptycs from a secure location during build instead of copying from local files

**Priority**: High - prevents large binaries in git history

---

## Medium Priority

### 2. Optimize container rebuild strategy
**Issue**: Currently using `--no-cache` for all container builds, which is slow

**Desired solution**:
- Only rebuild when Uptycs files change
- Use build cache for dependency layers
- Add checksum-based rebuild detection

---

## Low Priority

### 3. Add automated testing
- Test that Uptycs binaries are in built images
- Test that dm-verity is working
- Test that images boot successfully

### 4. Improve error messages
- Better diagnostics when builds fail
- Clear indication of which step failed
- Suggestions for common issues

### 5. Intercept this log on kickstart build better
- "cat /home/gcoon/gits/ibm_cloud_rhel9/logs/base-image-build-20260507-090223.log
