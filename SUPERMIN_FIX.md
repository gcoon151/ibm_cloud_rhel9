# Supermin/virt-customize Error Fix

## Problem
When running `virt-customize` inside a podman container, you may encounter:
```
virt-customize: error: libguestfs error: /usr/bin/supermin exited with error status 1.
```

## Root Cause
The libguestfs/supermin appliance builder needs access to the host's `/boot` directory to:
1. Access kernel modules
2. Build the appliance properly
3. Match kernel versions

Without the `/boot` mount, supermin cannot find the necessary kernel files and fails.

## Solution
In `example_run.sh`, the podman run command MUST include these mounts:

```bash
sudo podman run --rm \
    --privileged \
    -v $QCOW2:/disk.qcow2 \
    -v /lib/modules:/lib/modules:ro,Z \
    -v /boot:/boot:ro \              # CRITICAL: Required for supermin
    -v /dev:/dev \                   # CRITICAL: Required for device access
    --user 0 \
    --security-opt=apparmor=unconfined \
    --security-opt=seccomp=unconfined \
    --mount type=bind,source=/run/udev,target=/run/udev \
    localhost/coco-podvm
```

## Key Points
- **`-v /boot:/boot:ro`** - Absolutely required for supermin to work
- **`-v /dev:/dev`** - Required for NBD and device operations
- **`-v /lib/modules:/lib/modules:ro,Z`** - Required for kernel modules
- Must use `--privileged` mode
- Must run as root (`--user 0`)

## Environment Variable
Also set in the Dockerfile:
```dockerfile
ENV LIBGUESTFS_BACKEND=direct
```

## History
This issue has occurred multiple times when:
1. Refactoring the build scripts
2. Switching between branches
3. Simplifying mount configurations
4. Converting `-v` mounts to `--mount type=bind`

**Always verify these mounts are present when virt-customize fails!**

## Testing
To verify the fix works:
```bash
# Inside the container, test virt-customize
virt-customize -a /disk.qcow2 --run-command "echo test"
```

If it works without the supermin error, the mounts are correct.