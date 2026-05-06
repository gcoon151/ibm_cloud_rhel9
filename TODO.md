# TODO - Build System Improvements

## High Priority

### 1. Implement safe kernel removal
**Issue**: Removing old kernel breaks `agent-protocol-forwarder` service, preventing peer pods from starting.

**Current state**:
- Kickstart updates kernel to fix CVE-2026-31431
- Both old and new kernels are kept in the image
- Kernel removal code disabled in both kickstart and coco-components.sh

**Root cause**: Kernel removal (via `dnf remove`) breaks dependencies or removes kernel modules needed by agent-protocol-forwarder

**Desired solution**:
- Investigate exact dependency that breaks
- Either fix the dependency issue OR
- Accept having both kernels (adds ~200MB to image)
- Test thoroughly before re-enabling removal

**Files affected**:
- `helpers/rhel9-dm-root.ks` (lines 101-103)
- `scripts/coco/coco-components.sh` (lines 124-139, now commented out)

**Priority**: High - needed to reduce image size, but must not break functionality

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