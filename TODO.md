# TODO - Build System Improvements

## High Priority

### 1. Improve Uptycs tarball handling
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