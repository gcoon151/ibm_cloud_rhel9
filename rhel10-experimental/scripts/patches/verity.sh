#! /bin/bash
set -e

# Given a qcow2, apply dm-verity on it
#
# IBM MODIFICATIONS (layered on top of upstream coco-podvm-scripts):
#
# 1. sgdisk -e after qemu-img resize — operate on nbd block device, not QCOW2 file
#    qemu-img resize grows the virtual size but leaves the GPT secondary header at the
#    old disk offset. sgdisk -e MUST run on the block device exposed by qemu-nbd, NOT
#    on the QCOW2 file path. Running it on the QCOW2 file uses file_length as disk size
#    (not virtual-size), placing the backup header at the wrong offset. After nbd
#    connects the full virtual disk, the GPT is corrupt → find_efi_root_part() fails →
#    verity never runs. Fix: connect nbd, run sgdisk -e on the block device, disconnect,
#    then assert with sgdisk -v before continuing. (Deviation #9 in UPSTREAM_DEVIATIONS.md)
#
# 2. Hard assertion after modprobe nbd
#    modprobe nbd fails with "Operation not permitted" even inside --privileged
#    containers if the module isn't already loaded on the host kernel. Previously
#    the script silently continued: qemu-nbd failed, all subsequent steps were
#    skipped, but "Process completed!" was still printed. Now we assert /dev/nbd0
#    is a block device before continuing — the build fails loudly if it isn't.
#    Fix: load nbd on the host before podman run (build-rhel10-overlay.sh does this).
#    (Deviation #11 in UPSTREAM_DEVIATIONS.md)
#
# 3. Assertions after apply_dmverity and create_uki_addon
#    Verify that a verity partition was actually created and that verity.addon.efi
#    exists before declaring success.
#    (Deviation #11 in UPSTREAM_DEVIATIONS.md)

# Optional vars just for debug:
# CONSOLE_KERNEL= whether to add console=ttyS0 to /EFI/redhat/BOOTX64.CSV
# APPLY_VERITY= whether to add apply dm-verity and create addon

DISK=${DISK:-$1}

function local_help()
{
    echo "Usage: $0 <DISK>"
    echo "Usage: $0 help"
    echo ""
    echo "The purpose of this script is to take a disk and:"
    echo "1. Increase disk size by 10%"
    echo "2. create a new partition containing dm-verity hash tree of the root disk"
    echo "3. generate an UKI addon containing the verity root hash as kernel cmdline parameter"
    echo "4. put the addon in the ESP"
    echo "The resulting disk image is verity-protected and "
    echo "the root disk is overlayed by a tmpfs, which makes the root RW again but "
    echo "changes into that are not persistent after reboot."
    echo "Note that the disk has to have unallocated space to create the new partition."
    echo "The unallocated space has to be at least 10% of the root partition size."
    echo ""
    echo "Options (define them as variable):"
    echo "DISK:                mandatory - (var or arg) path of disk where to apply dm-verity. Must have 10% of the root disk unallocated."
    echo "DISK_FORMAT:         mandatory - disk format, can be qcow2, raw, vpc..."
    echo "RESIZE_DISK:         optional  - whether to increase disk size by 10% to accomodate verity partition. Default: yes"
    echo "SB_PRIVATE_KEY:      optional  - key to sign the verity cmdline addon. Default: don't sign"
    echo "SB_CERTIFICATE:      optional  - certificate in PEM format to upload in the gallery. Default: don't sign"
    echo "NBD_DEV:             optional  - nbd\$NBD_DEV where to temporarily mount the disk. Default: 0"
    echo "VERITY_FOLDER:       optional  - where to create verity artifacts. Defaults to a temp folder in /tmp"
    echo "ROOT_PARTITION_UUID: optional  - UUID to find the root. Defaults to the x86_64 part type"
    echo ""
    echo "Exiting"
}

if [[ $DISK == "help" ]]; then
    local_help
    exit 0
fi

if [ -z ${DISK} ]; then
    echo "DISK is unset. Either export DISK= or give it as parameter"
    exit 1
else
    echo "DISK=$DISK"
fi

if [ -z ${DISK_FORMAT} ]; then
    echo "DISK_FORMAT is unset. Set it with DISK_FORMAT={qcow2/raw/vpc}"
    exit 1
fi

here=`pwd`
DISK=$(realpath "$DISK")

VERITY_FOLDER=${VERITY_FOLDER:-$(mktemp -d)}
VERITY_FOLDER=$(realpath "$VERITY_FOLDER")

ADDON_SBAT="sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
coco-podvm-uki-addon,1,Red Hat,coco-podvm-uki-addon,1,mailto:secalert@redhat.com"

# Unallocated space added to the disk for the boot-time LUKS scratch partition
# (create-scratch.sh, no SizeMaxBytes). Guest-pulled images unpack there, so this is the
# pod VM's total image-pull capacity: compressed layers + unpacked files at the same time.
# CAA does not set an IBM Cloud boot-volume size, so the disk is the image size.
# Format time does not depend on size (pbkdf2 + lazy mkfs: ~35 MB written at 256 MB-10 GB).
LUKS_MINIMAL_SPACE_MB=8192
# VERITY_MAX_SPACE_MB=512

nbd_mounted=0
esp_mounted=0

function print_params()
{
    echo ""
    echo "VERITY_FOLDER: $VERITY_FOLDER"
    echo "DISK: $DISK"
    echo "DISK_FORMAT: $DISK_FORMAT"
    echo "RESIZE_DISK: $RESIZE_DISK"
    if [[ -n "${SB_PRIVATE_KEY}" && -n "${SB_CERTIFICATE}" ]]; then
        echo "SB_PRIVATE_KEY: $SB_PRIVATE_KEY"
        echo "SB_CERTIFICATE: $SB_CERTIFICATE"
    fi
    echo "NBD_DEV: $NBD_DEV"
    echo ""
}

function handle_ctrlc()
{
    local EXIT_CODE=$?
    if [[ $root_mounted == 1 ]]; then
        umount $VERITY_FOLDER/mnt
    fi
    if [[ $esp_mounted == 1 ]]; then
        umount $VERITY_FOLDER/mnt
    fi
    if [[ $nbd_mounted == 1 ]]; then
        qemu-nbd --disconnect $NBD_DEVICE
    fi
    # rm -rf $VERITY_FOLDER
    cd $here
    # IBM MOD: preserve the original exit code — upstream always exits 0 from the trap,
    # which means set -e failures inside verity.sh are swallowed and create-verity-podvm.sh
    # continues to print "Process completed!" even on fatal errors.
    exit $EXIT_CODE
}

trap handle_ctrlc SIGINT
trap handle_ctrlc EXIT

DISK_FORMAT=${DISK_FORMAT:-"raw"}
APPLY_VERITY=${APPLY_VERITY:-"true"}
CONSOLE_KERNEL=${CONSOLE_KERNEL:-"false"}
ROOT_PARTITION_UUID=${ROOT_PARTITION_UUID:-"4f68bce3-e8cd-4db1-96e7-fbcaf984b709"}
NBD_DEV=${NBD_DEV:-"0"}
NBD_DEVICE=/dev/nbd${NBD_DEV}
RESIZE_DISK=${RESIZE_DISK:-"yes"}

EFI_PARTITION_UUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
CONSOLE_CMDLINE="console=ttyS0"

MB=$((1024 * 1024))
# IBM MOD: margin left free inside the shrunk root filesystem, and around the verity hash.
ROOT_MARGIN_MB=64
VERITY_MIN_MB=64

function resize_disk()
{
    # IBM MOD: resize to an explicit target (computed by shrink_root_to_fit) instead of
    # "current + LUKS_MINIMAL_SPACE_MB + 7%". The target may be smaller than the current size.
    DISK_RESIZE=$1
    rounded_size=$(( ($2 + MB - 1) / MB * MB ))
    current_size=$(qemu-img info -f $DISK_FORMAT --output json $DISK_RESIZE | jq '."virtual-size"')
    echo "Current disk size: $current_size"
    echo "New disk size: $rounded_size"
    if (( rounded_size < current_size )); then
        qemu-img resize --shrink "$DISK_RESIZE" -f $DISK_FORMAT "${rounded_size}"
    else
        qemu-img resize "$DISK_RESIZE" -f $DISK_FORMAT "${rounded_size}"
    fi
    echo "Image resized."

    # IBM MOD: Relocate GPT backup header to new end of disk via nbd block device.
    # qemu-img resize grows the virtual size but leaves the GPT secondary header at the
    # old offset. sgdisk -e MUST run on the nbd block device — running it on the QCOW2
    # file path uses file_length (not virtual-size) as disk size, placing the backup
    # header at the wrong offset. After nbd exposes the full virtual disk the GPT is
    # corrupt → find_efi_root_part() fails → verity never runs.
    #
    # Note: nbd connect requires partprobe + settle + sleep before sgdisk can read the
    # partition table reliably. udevadm settle alone is not sufficient — the kernel
    # partition table read is asynchronous. Without the sleep, sgdisk sees MBR (read
    # error 22 = EINVAL on uninitialized offsets) and exits 0 with "Non-GPT disk".
    # Deviation #9 in UPSTREAM_DEVIATIONS.md.
    echo "Relocating GPT backup header to end of disk (via nbd block device)..."
    qemu-nbd -c "$NBD_DEVICE" -f "$DISK_FORMAT" "$DISK_RESIZE"
    udevadm settle
    partprobe "$NBD_DEVICE"
    udevadm settle
    sleep 2
    sgdisk -e "$NBD_DEVICE"
    SGDISK_RC=$?
    qemu-nbd --disconnect "$NBD_DEVICE"
    udevadm settle
    sleep 1
    if [[ $SGDISK_RC -ne 0 ]]; then
        echo "ERROR: sgdisk -e failed (rc=$SGDISK_RC)" >&2
        exit 1
    fi
    # Assert GPT is actually clean now — upstream prints success unconditionally
    RAW_TMP=$(mktemp /tmp/gpt-check-XXXXXX.raw)
    qemu-img convert -f "$DISK_FORMAT" -O raw "$DISK_RESIZE" "$RAW_TMP"
    sgdisk -v "$RAW_TMP" || { echo "ERROR: GPT still corrupt after sgdisk -e" >&2; rm -f "$RAW_TMP"; exit 1; }
    rm -f "$RAW_TMP"
    echo "✓ GPT backup header relocated and verified"
}

function find_efi_root_part()
{
    echo "Searching for root partition..."
    EFI_PN=$(lsblk -o NAME,PARTTYPE -r $NBD_DEVICE | grep $EFI_PARTITION_UUID)
    num_results=$(echo "$EFI_PN" | wc -l)
    if [[ "$num_results" -ne 1 || -z "$EFI_PN" ]]; then
        echo "Error: Expected one EFI System Partition, found $num_results."
        exit 1
    fi
    EFI_PN=$(echo $EFI_PN | awk '{print  $1}')
    echo EFI PARTITION=$EFI_PN

    ROOT_PN=$(lsblk -o NAME,PARTTYPE -r $NBD_DEVICE | grep $ROOT_PARTITION_UUID)
    num_results=$(echo "$ROOT_PN" | wc -l)
    if [[ "$num_results" -ne 1 || -z "$ROOT_PN" ]]; then
        echo "Error: Expected one Root $ROOT_PARTITION_UUID, found $num_results."
        exit 1
    fi
    ROOT_PN=$(echo $ROOT_PN | awk '{print  $1}')
    echo ROOT PARTITION=$ROOT_PN
}

function fix_bootx_cmdline()
{
    mount /dev/$EFI_PN mnt
    esp_mounted=1
    BOOTX_FILE=mnt/EFI/redhat/BOOTX64.CSV
    cat $BOOTX_FILE  | iconv -f UCS-2 | tee tmp-bootx > /dev/null
    sed -i "s/\( *\),UKI/ $CONSOLE_CMDLINE\1,UKI/" tmp-bootx
    mv $BOOTX_FILE $BOOTX_FILE.orig
    cat tmp-bootx |  iconv -t UCS-2 | tee $BOOTX_FILE > /dev/null
    cat $BOOTX_FILE
    rm -rf tmp-bootx
    esp_mounted=0
    umount mnt
}

function call_fsck()
{
    fs_type=$(blkid -o value -s TYPE /dev/$ROOT_PN)
    fsck.$fs_type -p /dev/$ROOT_PN
    echo "fsck applied"
}

function shrink_root_to_fit()
{
    # IBM MOD: dm-verity makes root read-only, so free space inside it can never be used.
    # The kickstart's root uses --grow so the build has room for dnf installs; here, after
    # every write to root is done (coco-components.sh runs before verity.sh), shrink the
    # root filesystem and partition to the contents + ROOT_MARGIN_MB. Then size the verity
    # hash from the real root size and set the disk to root end + hash + scratch reserve.
    # Everything left over becomes the boot-time LUKS scratch partition (create-scratch.sh).
    local fs_type root_num last_node block_size min_blocks cur_blocks target_blocks
    local root_start root_sectors root_end
    fs_type=$(blkid -o value -s TYPE /dev/$ROOT_PN)
    if [[ "$fs_type" != "ext4" ]]; then
        echo "ERROR: root filesystem is '$fs_type'; shrink_root_to_fit supports ext4 only" >&2
        exit 1
    fi
    last_node=$(sfdisk -J "$NBD_DEVICE" | jq -r '.partitiontable.partitions | max_by(.start) | .node')
    if [[ "$last_node" != "/dev/$ROOT_PN" ]]; then
        echo "ERROR: root (/dev/$ROOT_PN) is not the last partition ($last_node); cannot shrink in place" >&2
        exit 1
    fi
    root_num=$(cat /sys/class/block/$ROOT_PN/partition)

    # e2fsck exits 1 when it corrected something; only >1 is a failure.
    e2fsck -f -y /dev/$ROOT_PN || [ $? -le 1 ]
    block_size=$(dumpe2fs -h /dev/$ROOT_PN 2>/dev/null | awk -F: '/^Block size/ {gsub(/ /, "", $2); print $2}')
    cur_blocks=$(dumpe2fs -h /dev/$ROOT_PN 2>/dev/null | awk -F: '/^Block count/ {gsub(/ /, "", $2); print $2}')
    min_blocks=$(resize2fs -P /dev/$ROOT_PN 2>/dev/null | awk -F: '/minimum size/ {gsub(/ /, "", $2); print $2}')
    target_blocks=$(( min_blocks + ROOT_MARGIN_MB * MB / block_size ))
    # Round the filesystem to whole MiB so the partition can match it exactly.
    target_blocks=$(( (target_blocks * block_size + MB - 1) / MB * MB / block_size ))
    echo "Root fs: ${cur_blocks} blocks now, ${min_blocks} minimum, ${target_blocks} target (${block_size} B blocks)"
    if (( target_blocks < cur_blocks )); then
        resize2fs /dev/$ROOT_PN "$target_blocks"
        root_sectors=$(( target_blocks * block_size / 512 ))
        # Same start, type and UUID; only the size changes.
        echo ",${root_sectors}" | sfdisk --no-reread --no-tell-kernel -N "$root_num" "$NBD_DEVICE"
        partprobe "$NBD_DEVICE"
        udevadm settle
        sleep 2
        e2fsck -f -n /dev/$ROOT_PN
    fi

    root_start=$(sfdisk -J "$NBD_DEVICE" | jq -r ".partitiontable.partitions[] | select(.node == \"/dev/$ROOT_PN\") | .start")
    root_sectors=$(sfdisk -J "$NBD_DEVICE" | jq -r ".partitiontable.partitions[] | select(.node == \"/dev/$ROOT_PN\") | .size")
    root_size_bytes=$(( root_sectors * 512 ))
    root_end=$(( (root_start + root_sectors) * 512 ))
    # systemd-repart (252) builds the hash with 512-byte hash blocks on 512-byte-sector disks:
    # 16 sha256 digests per block, so the tree is ~1/15 of the data (measured: 94163968 bytes
    # for 1412431872). That is where upstream's flat "7% of the disk" came from.
    verity_max_space=$(( (root_size_bytes / 15 + 8 * MB + MB - 1) / MB * MB ))
    (( verity_max_space < VERITY_MIN_MB * MB )) && verity_max_space=$(( VERITY_MIN_MB * MB ))
    # + 2 MiB: partition alignment and the GPT backup header.
    target_disk_size=$(( root_end + verity_max_space + LUKS_MINIMAL_SPACE_MB * MB + 2 * MB ))
    root_min_line="SizeMinBytes=${root_size_bytes}"
    export root_size_bytes verity_max_space target_disk_size root_min_line
    echo "Root partition: $(( root_size_bytes / MB )) MiB; verity: $(( verity_max_space / MB )) MiB; scratch reserve: ${LUKS_MINIMAL_SPACE_MB} MiB; disk target: $(( target_disk_size / MB )) MiB"
}

function apply_dmverity()
{
    # create config files and folders for systemd-repart and UKI
    WORKDIR=conf
    mkdir $WORKDIR

    # IBM MOD: hash partition sized from the real root (shrink_root_to_fit), fixed size and
    # no PaddingWeight, so it doesn't swallow free space meant for the scratch partition.
    echo "[Partition]
    Type=root-verity
    Verity=hash
    VerityMatchKey=root
    SizeMinBytes=${verity_max_space}
    SizeMaxBytes=${verity_max_space}" > $WORKDIR/verity.conf

    # Used just to reference the root. IBM MOD: pin root to its current (shrunk) size, or
    # systemd-repart grows it back into the free space.
    echo "[Partition]
    Type=root
    Verity=data
    VerityMatchKey=root
    ${root_min_line}
    SizeMaxBytes=${root_size_bytes}" > $WORKDIR/root.conf

    SYSTEMD_LOG_LEVEL=debug systemd-repart $NBD_DEVICE --dry-run=no --definitions=$WORKDIR --no-pager --json=pretty | jq -r '.[] | select(.type == "root-x86-64-verity") | .roothash' > $WORKDIR/roothash.txt
    RH=$(cat $WORKDIR/roothash.txt)
    rm -rf $WORKDIR

    partprobe $NBD_DEVICE
    # Allow udev events to settle again after partprobe
    udevadm settle
    sleep 2

    # IBM MOD: systemd-repart writes the verity partition but leaves the GPT backup
    # header corrupt (it does not call sgdisk -e). Must re-relocate backup header
    # after repart, while nbd is still connected.
    # Deviation #9 in UPSTREAM_DEVIATIONS.md.
    echo "Re-relocating GPT backup header after systemd-repart..."
    sgdisk -e "$NBD_DEVICE"
    udevadm settle
    sleep 1
    echo "✓ GPT backup header re-relocated after repart"

    if [ "$RH" == "TBD" ]; then
        echo "roothash is TBD, something went wrong. Make sure the image you are using doesn't have a /verity partition already!"
        echo "Exiting."
        exit 1
    fi

    echo "Root hash: $RH"

    # IBM MOD: Assert verity partition was actually created.
    # Use sgdisk -p (raw partition listing) rather than lsblk PARTTYPE — lsblk
    # PARTTYPE field is unreliable for newly-created nbd partitions until the kernel
    # re-reads the table. sgdisk reads directly from the device.
    # Deviation #11 in UPSTREAM_DEVIATIONS.md.
    PART_COUNT=$(lsblk -r $NBD_DEVICE | grep -c "^nbd" || true)
    echo "Partition count after verity: $PART_COUNT"
    if ! sgdisk -p "$NBD_DEVICE" 2>/dev/null | grep -qi "root-x86-64-verity\|830C"; then
        echo "ERROR: verity hash partition (root-x86-64-verity / type 830C) not found after systemd-repart" >&2
        echo "       systemd-repart may have silently failed." >&2
        exit 1
    fi
    echo "✓ Verity hash partition present"

    export RH
}

function inject_grub_cmdline()
{
    echo "Injecting verity command line into GRUB BLS entries..."
    
    # 1. Determine partition UNIQUE GUID (PARTUUID) for root and verity partitions
    get_part_uuid_and_type() {
        local dev="$1"
        local pnum="$2"
        sgdisk -i "$pnum" "$dev" 2>/dev/null | grep -i "Partition unique GUID" | awk '{print $4}' | tr '[:upper:]' '[:lower:]'
    }
    get_part_type_guid() {
        local dev="$1"
        local pnum="$2"
        sgdisk -i "$pnum" "$dev" 2>/dev/null | grep -i "Partition GUID code" | awk '{print $4}' | tr '[:upper:]' '[:lower:]'
    }

    local ROOT_PARTUUID=""
    local VERITY_PARTUUID=""
    local BOOT_PART_NUM=""

    local PART_COUNT=$(sgdisk -p "$NBD_DEVICE" | grep -E "^[[:space:]]*[0-9]+" | awk '{print $1}' | sort -n | tail -1)
    for pnum in $(seq 1 "$PART_COUNT"); do
        local TYPE_GUID=$(get_part_type_guid "$NBD_DEVICE" "$pnum")
        if [[ "$TYPE_GUID" == *"4f68bce3-e8cd-4db1-96e7-fbcaf984b709"* ]]; then
            ROOT_PARTUUID=$(get_part_uuid_and_type "$NBD_DEVICE" "$pnum")
        fi
        if [[ "$TYPE_GUID" == *"2c7357ed-ebd2-46d9-aec1-23d437ec2bf5"* ]]; then
            VERITY_PARTUUID=$(get_part_uuid_and_type "$NBD_DEVICE" "$pnum")
        fi
        # /boot partition can be BC13C2FF-... (xbootldr) or 0FC63DAF-... (linux-generic)
        if [[ "$TYPE_GUID" == *"bc13c2ff-59e6-4262-a352-b275fd6f7172"* || "$TYPE_GUID" == *"0fc63daf-8483-4772-8e79-3d69d8477de4"* ]]; then
            if blkid -o value -s TYPE "${NBD_DEVICE}p${pnum}" 2>/dev/null | grep -q "ext4"; then
                BOOT_PART_NUM="$pnum"
            fi
        fi
    done

    if [[ -z "$ROOT_PARTUUID" || -z "$VERITY_PARTUUID" || -z "$BOOT_PART_NUM" ]]; then
        echo "ERROR: failed to identify all partitions: root=$ROOT_PARTUUID, verity=$VERITY_PARTUUID, boot=$BOOT_PART_NUM" >&2
        exit 1
    fi
    echo "  Root Partition unique GUID:   $ROOT_PARTUUID"
    echo "  Verity Partition unique GUID: $VERITY_PARTUUID"
    echo "  Boot partition number:        $BOOT_PART_NUM"

    # 2. Mount the /boot partition read-write
    local boot_dev="${NBD_DEVICE}p${BOOT_PART_NUM}"
    mount "$boot_dev" mnt
    boot_mounted=1

    # 3. Remove rescue BLS entry if present — plan §4.1 requires exactly one entry.
    # kernel-install creates it during Anaconda install regardless of kickstart settings.
    if ls mnt/loader/entries/*-rescue.conf 2>/dev/null; then
        echo "  Removing rescue BLS entry/entries..."
        rm -f mnt/loader/entries/*-rescue.conf
    fi

    # 4. Check exactly one BLS entry exists
    local bls_entries=(mnt/loader/entries/*.conf)
    if [[ ${#bls_entries[@]} -eq 0 || ! -f "${bls_entries[0]}" ]]; then
        echo "ERROR: No BLS entry files found in /boot/loader/entries/" >&2
        exit 1
    fi
    if [[ ${#bls_entries[@]} -gt 1 ]]; then
        echo "ERROR: Multiple BLS entries after rescue removal — expected exactly 1:" >&2
        ls mnt/loader/entries/*.conf >&2
        exit 1
    fi

    # 5. For each entry, rewrite the options line
    for entry in "${bls_entries[@]}"; do
        echo "  Processing BLS entry: $entry"
        local current_options=$(grep "^options " "$entry" | cut -d' ' -f2-)
        # Strip old properties and clean whitespace
        local cleaned_options=$(echo "$current_options" | sed -E -e 's/root=[^ ]+//g' -e 's/rhgb//g' -e 's/quiet//g' -e 's/crashkernel=[^ ]+//g' | tr -s ' ')
        
        # New verity options to append (explicit verity_root properties are required since systemd-gpt-auto-generator
        # relies on LoaderDevicePartUUID which systemd-stub sets but grub does not).
        local verity_opts="root=/dev/mapper/root systemd.verity_root_data=PARTUUID=${ROOT_PARTUUID} systemd.verity_root_hash=PARTUUID=${VERITY_PARTUUID} roothash=${RH} systemd.verity_root_options=panic-on-corruption systemd.volatile=overlay console=ttyS0"
        
        sed -i "s|^options .*|options ${cleaned_options} ${verity_opts}|" "$entry"
        echo "    New options: $(grep "^options " "$entry")"
    done

    # 6. Assertions
    local entries_count=${#bls_entries[@]}
    local match_count=$(grep -c "roothash=${RH}" mnt/loader/entries/*.conf || echo 0)
    if [[ "$match_count" -ne "$entries_count" ]]; then
        echo "ERROR: not all BLS entries were successfully updated with roothash=$RH" >&2
        exit 1
    fi
    echo "✓ Successfully updated $match_count BLS entries with roothash=$RH"

    umount mnt
    boot_mounted=0
}

function create_uki_addon()
{
    UKI_FOLDER=mnt/EFI/Linux
    ADDON_NAME=verity.addon.efi
    mount /dev/$EFI_PN mnt
    esp_mounted=1
    efi_files=($UKI_FOLDER/*.efi)

    # Check if any EFI files exist
    if [[ ${#efi_files[@]} -eq 0 || ! -f "${efi_files[0]}" ]]; then
        echo "Error: No .efi files found in $UKI_FOLDER"
        exit 1
    fi

    # If multiple files, pick the most recent one
    if [[ ${#efi_files[@]} -gt 1 ]]; then
        echo "Found ${#efi_files[@]} EFI files: ${efi_files[@]}"
        echo ""
        echo "Current EFI fallback value (/boot/efi/EFI/redhat/BOOTX64.CSV):"
        cat mnt/EFI/redhat/BOOTX64.CSV
        echo ""
        echo "Selecting the most recently modified UKI..."
        UKI_NAME=$(ls -t "${efi_files[@]}" | head -1)
    else
        UKI_NAME=${efi_files[0]}
    fi

    echo "Using UKI: $UKI_NAME"
    mkdir -p "$UKI_NAME.extra.d"
    cd $UKI_NAME.extra.d
    rm -f $ADDON_NAME

    if [[ -n "$SB_PRIVATE_KEY" && -n "$SB_CERTIFICATE" ]]; then
        ADDON_OPTIONS="--secureboot-private-key=$SB_PRIVATE_KEY --secureboot-certificate=$SB_CERTIFICATE"
        echo "Signing addon with $SB_PRIVATE_KEY and $SB_CERTIFICATE"
    fi
    /usr/lib/systemd/ukify build --cmdline="roothash=$RH systemd.volatile=overlay" --output=$ADDON_NAME --sbat="$ADDON_SBAT" $ADDON_OPTIONS
    echo "Created UKI addon $UKI_NAME.extra.d/$ADDON_NAME"
    /usr/lib/systemd/ukify inspect $ADDON_NAME

    # IBM MOD: Assert verity addon was actually written — check BEFORE unmounting ESP.
    # Deviation #11 in UPSTREAM_DEVIATIONS.md.
    # We already cd'd into $UKI_NAME.extra.d so $ADDON_NAME is a bare filename here.
    # Checking the full path ($UKI_NAME.extra.d/$ADDON_NAME) is wrong — it would be
    # relative to the already-changed CWD and always fail even when the file exists.
    if [[ ! -f "$ADDON_NAME" ]]; then
        echo "ERROR: $UKI_NAME.extra.d/$ADDON_NAME not found after ukify build" >&2
        exit 1
    fi
    echo "✓ Verity addon present: $UKI_NAME.extra.d/$ADDON_NAME"

    cd - > /dev/null
    esp_mounted=0
    umount mnt
}

print_params

cd $VERITY_FOLDER

mkdir mnt

if [ "$RESIZE_DISK" = "yes" ]; then
    # IBM MOD: shrink root to its contents first, then resize the disk to fit (see
    # shrink_root_to_fit). nbd is connected for the shrink and disconnected for the resize.
    echo ""
    echo "Shrinking root to fit, then resizing disk..."
    modprobe nbd 2>/dev/null || true
    nbd_mounted=1
    qemu-nbd -c $NBD_DEVICE -f $DISK_FORMAT $DISK
    # Fresh nbd connect: the partition table read is async (see Deviation #9).
    udevadm settle
    partprobe "$NBD_DEVICE"
    udevadm settle
    sleep 2
    find_efi_root_part
    call_fsck
    shrink_root_to_fit
    qemu-nbd --disconnect $NBD_DEVICE
    nbd_mounted=0
    udevadm settle
    sleep 1
    resize_disk $DISK $target_disk_size
else
    current_size=$(qemu-img info -f $DISK_FORMAT --output json $DISK | jq '."virtual-size"')
    # RESIZE_DISK=no: upstream sizing, root not pinned (it can't grow: no free space added).
    root_size_bytes=$current_size
    root_min_line=""
    verity_max_space=$(( current_size * 7 / 100 ))
fi

# IBM MOD: Assert nbd is available before attempting to use it.
# modprobe nbd fails inside a container even with --privileged if the host kernel
# doesn't have the module loaded. build-rhel10-overlay.sh loads nbd on the host
# before podman run, so /dev/nbd0 should already exist here.
# We still attempt modprobe (no-op if already loaded) but treat failure as non-fatal
# since the host may have pre-loaded it. What IS fatal: /dev/nbd0 not being a block device.
# Deviation #11 in UPSTREAM_DEVIATIONS.md.
modprobe nbd 2>/dev/null || true
if [[ ! -b "$NBD_DEVICE" ]]; then
    echo "ERROR: $NBD_DEVICE is not a block device." >&2
    echo "       The nbd kernel module must be loaded on the HOST before running this container." >&2
    echo "       Run: sudo modprobe nbd max_part=8" >&2
    exit 1
fi
echo "✓ $NBD_DEVICE is available"
nbd_mounted=1
qemu-nbd -c $NBD_DEVICE -f $DISK_FORMAT $DISK
udevadm settle
sleep 2

# Step 1. Find the EFI partition automatically
echo ""
find_efi_root_part

# Step 2. Apply cmdline to /EFI/redhat/BOOTX64.CSV
if [ "$CONSOLE_KERNEL" = "true" ]; then
    echo ""
    fix_bootx_cmdline
fi

echo ""
call_fsck

if [ "$APPLY_VERITY" = "true" ]; then
    # Step 3. Apply verity
    echo ""
    apply_dmverity

    # Step 4. Prepare and install the addon or inject GRUB cmdline
    echo ""
    if [ "${BOOT_MODE:-uki}" = "grub" ]; then
        inject_grub_cmdline
    else
        create_uki_addon
    fi
fi


# Cleanup
qemu-nbd --disconnect $NBD_DEVICE
nbd_mounted=0
rm -rf mnt
cd $here
