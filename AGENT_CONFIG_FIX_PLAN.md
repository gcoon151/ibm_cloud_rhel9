# Plan to Fix agent-config.toml Missing Settings

## Problem Statement
Red Hat's `osc-podvm-payload-rhel9:ffb785e` image contains an incomplete `/etc/agent-config.toml` with only 3 settings instead of 5. Missing:
- `enable_signature_verification = true`
- `image_policy_file = "/etc/containers/policy.json"`

## Investigation & Verification Plan

### Phase 1: Verify Container Has Updated Script

**Check if coco-podvm container has the patch code:**
```bash
ssh gcoon@192.168.1.196 "podman run --rm localhost/coco-podvm cat /scripts/coco/podvm/podvm_maker.sh | head -40"
```

**Expected output:** Should show the patch code (lines 8-35) with "Patching agent-config.toml..."

**If patch is missing:** Container needs rebuild
```bash
ssh gcoon@192.168.1.196 "cd ~/gits/ibm_cloud_rhel9 && sudo podman build --no-cache -t coco-podvm -f Dockerfile ."
```

### Phase 2: Enhance Logging in podvm_maker.sh

**Current patch code has debug logging, but add more visible markers:**

Add to `ibm_cloud_rhel9/scripts/coco/podvm/podvm_maker.sh` after line 35:
```bash
# Create marker file to prove patch executed
echo "Patch executed at $(date)" > /AGENT_CONFIG_PATCHED
echo "✓ Created marker file /AGENT_CONFIG_PATCHED"
```

This creates a file we can check in the QCOW2 to prove the patch ran.

### Phase 3: Run Build and Capture Logs

**Run build with output capture:**
```bash
ssh gcoon@192.168.1.196 "cd ~/gits/ibm_cloud_rhel9 && ./build/build-podvm.sh qcow2 2>&1 | tee /tmp/build-with-patch.log"
```

**Check logs for patch execution:**
```bash
ssh gcoon@192.168.1.196 "grep -A 20 'Patching agent-config.toml' /tmp/build-with-patch.log"
```

**Expected output:**
```
========================================
Patching agent-config.toml...
========================================
DEBUG: Checking if /etc/agent-config.toml exists...
DEBUG: File exists, current content:
server_addr = "unix:///run/kata-containers/agent.sock"
guest_components_procs = "none"
image_registry_auth = "file:///run/peerpod/auth.json"
DEBUG: Applying patch...
✓ Added enable_signature_verification
✓ Added image_policy_file
DEBUG: After patch:
server_addr = "unix:///run/kata-containers/agent.sock"
guest_components_procs = "none"
image_registry_auth = "file:///run/peerpod/auth.json"
enable_signature_verification = true
image_policy_file = "/etc/containers/policy.json"
✓ agent-config.toml patching complete
```

### Phase 4: Verify QCOW2 After Build

**Check marker file exists:**
```bash
ssh gcoon@192.168.1.196 "cd ~/gits/ibm_cloud_rhel9 && podman run --rm -v /home/gcoon/.local/share/libvirt/images:/images:ro localhost/coco-podvm virt-cat -a /images/rhel97-YYYYMMDDNN.qcow2 /AGENT_CONFIG_PATCHED"
```

**Expected:** Should show "Patch executed at [timestamp]"

**Check agent-config.toml has 5 lines:**
```bash
ssh gcoon@192.168.1.196 "cd ~/gits/ibm_cloud_rhel9 && podman run --rm -v /home/gcoon/.local/share/libvirt/images:/images:ro localhost/coco-podvm virt-cat -a /images/rhel97-YYYYMMDDNN.qcow2 /etc/agent-config.toml"
```

**Expected output (5 lines):**
```toml
server_addr = "unix:///run/kata-containers/agent.sock"
guest_components_procs = "none"
image_registry_auth = "file:///run/peerpod/auth.json"
enable_signature_verification = true
image_policy_file = "/etc/containers/policy.json"
```

**Count lines to verify:**
```bash
ssh gcoon@192.168.1.196 "cd ~/gits/ibm_cloud_rhel9 && podman run --rm -v /home/gcoon/.local/share/libvirt/images:/images:ro localhost/coco-podvm virt-cat -a /images/rhel97-YYYYMMDDNN.qcow2 /etc/agent-config.toml | wc -l"
```

**Expected:** 5

### Phase 5: Deploy and Verify in Running Pod

**Deploy test pod:**
```bash
./scripts/remote-build.sh vsi-only  # Create VSI from QCOW2
oc apply -f configs/test-podvm-image.yaml
```

**Wait for pod to be Running, then verify:**
```bash
VXLAN_IP=$(./scripts/get-pod-vxlan-ip.sh test-podvm-candidate default 2>&1 | grep -oE '10\.241\.[0-9]+\.[0-9]+' | head -1)
./scripts/node-ssh-wrapper.sh "$VXLAN_IP" "cat /etc/agent-config.toml"
./scripts/node-ssh-wrapper.sh "$VXLAN_IP" "cat /etc/agent-config.toml | wc -l"
```

**Expected:** 5 lines with both signature verification settings

## Execution Order

1. **Verify container has patch** → If not, rebuild container
2. **Add marker file creation** to podvm_maker.sh for easier verification
3. **Run build** with log capture
4. **Check build logs** for patch execution output
5. **Verify QCOW2** has marker file and 5-line agent-config.toml
6. **Deploy pod** and verify in running environment
7. **Document success** in working_list.txt

## Why This Approach Works

- **Verifies each step** before proceeding to next
- **Uses container inspection** to confirm script version
- **Captures logs** to see what actually executed
- **Checks QCOW2 directly** before deploying
- **Validates in running pod** as final confirmation
- **Creates marker files** for easy verification

## Files to Modify

1. `ibm_cloud_rhel9/scripts/coco/podvm/podvm_maker.sh` - Add marker file creation after patch (optional but helpful)

## Commands to Run (in order)

1. Check container: `podman run --rm localhost/coco-podvm cat /scripts/coco/podvm/podvm_maker.sh | head -40`
2. If needed, rebuild: `sudo podman build --no-cache -t coco-podvm -f Dockerfile .`
3. Run build: `./build/build-podvm.sh qcow2 2>&1 | tee /tmp/build-with-patch.log`
4. Check logs: `grep -A 20 'Patching agent-config.toml' /tmp/build-with-patch.log`
5. Verify QCOW2: `podman run --rm -v /home/gcoon/.local/share/libvirt/images:/images:ro localhost/coco-podvm virt-cat -a /images/rhel97-YYYYMMDDNN.qcow2 /etc/agent-config.toml`
6. Deploy and test