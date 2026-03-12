#!/bin/bash
# Dracut module for dm-verity root filesystem protection
# This module runs in initramfs BEFORE root mount

check() {
    # Only include if dm-verity tools are available
    require_binaries dmsetup veritysetup || return 1
    return 0
}

depends() {
    # Require systemd for initrd services
    echo systemd
    return 0
}

install() {
    # Install dm-verity setup script
    inst_hook pre-mount 50 "$moddir/dmverity-setup.sh"
    
    # Install required binaries
    inst_multiple dmsetup veritysetup blockdev base64 gzip grep cut tr
    
    # Install kernel modules
    instmods dm-verity dm-mod
    
    # Create directories for roothash storage
    mkdir -p "${initdir}/run/dmverity"
    
    return 0
}

# Made with Bob
