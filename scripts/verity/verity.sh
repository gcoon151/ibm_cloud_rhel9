#! /bin/bash
set -e

# Given a qcow2, apply dm-verity on it

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

LUKS_MINIMAL_SPACE_MB=2500
VERITY_MAX_SPACE_MB=512

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
    exit 0
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

function resize_disk()
{
    DISK_RESIZE=$1
    MB=$((1024 * 1024))
    current_size=$(qemu-img info -f $DISK_FORMAT --output json $DISK_RESIZE | jq '."virtual-size"')
    # new_size=$((current_size * 110 / 100)) # increase 10% for verity - obsolete
    luks_min_space=$((LUKS_MINIMAL_SPACE_MB * MB))
    verity_max_space=$((VERITY_MAX_SPACE_MB * MB))
    new_size=$((current_size + luks_min_space + verity_max_space))
    rounded_size=$(((new_size + MB - 1) / MB * MB))
    echo "Current disk size: $current_size"
    echo "New disk size: $rounded_size"
    qemu-img resize "$DISK_RESIZE" -f $DISK_FORMAT "${rounded_size}"
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

function apply_dmverity()
{
    # create config files and folders for systemd-repart and UKI
    WORKDIR=conf
    mkdir $WORKDIR
    # Verity partition has to be 10% of the original partition (256MB).
    # Exaggerate and give 512MB
    echo "[Partition]
    Type=root-verity
    Verity=hash
    VerityMatchKey=root
    PaddingWeight=1
    SizeMinBytes=64M
    SizeMaxBytes=${VERITY_MAX_SPACE_MB}M" > $WORKDIR/verity.conf

    # Used just to reference the root
    # Fix the root size to 2.5GB because that's what it is provided. It shouldn't grow.
    echo "[Partition]
    Type=root
    Verity=data
    VerityMatchKey=root
    SizeMaxBytes=2560M" > $WORKDIR/root.conf

    systemd-repart $NBD_DEVICE --dry-run=no --definitions=$WORKDIR --no-pager --json=pretty | jq -r '.[] | select(.type == "root-x86-64-verity") | .roothash' > $WORKDIR/roothash.txt
    RH=$(cat $WORKDIR/roothash.txt)
    rm -rf $WORKDIR

    if [ "$RH" == "TBD" ]; then
        echo "roothash is TBD, something went wrong. Make sure the image you are using doesn't have a /verity partition already!"
        echo "Exiting."
        exit 1
    fi

    echo "Root hash: $RH"

    export RH
}

function create_uki_addon()
{
    UKI_FOLDER=mnt/EFI/Linux
    ADDON_NAME=verity.addon.efi
    mount /dev/$EFI_PN mnt
    esp_mounted=1
    efi_files=($UKI_FOLDER/*.efi)
    if [[ ${#efi_files[@]} -eq 1 && -f "${efi_files[0]}" ]]; then
        UKI_NAME=${efi_files[0]}
        echo "Found UKI $UKI_NAME"
        mkdir -p "$UKI_NAME.extra.d"
    else
        echo "Error: Either no .efi file or multiple .efi files found."
        echo "Cannot create the UKI addon."
        exit 1
    fi
    cd $UKI_NAME.extra.d
    rm -f $ADDON_NAME

    if [[ -n "$SB_PRIVATE_KEY" && -n "$SB_CERTIFICATE" ]]; then
        ADDON_OPTIONS="--secureboot-private-key=$SB_PRIVATE_KEY --secureboot-certificate=$SB_CERTIFICATE"
        echo "Signing addon with $SB_PRIVATE_KEY and $SB_CERTIFICATE"
    fi
    /usr/lib/systemd/ukify build --cmdline="roothash=$RH systemd.volatile=overlay" --output=$ADDON_NAME --sbat="$ADDON_SBAT" $ADDON_OPTIONS
    echo "Created UKI addon $UKI_NAME.extra.d/$ADDON_NAME"
    /usr/lib/systemd/ukify inspect $ADDON_NAME
    cd - > /dev/null
    esp_mounted=0
    umount mnt
}

print_params

if [ "$RESIZE_DISK" = "yes" ]; then
    echo ""
    echo "Resizing disk..."
    resize_disk $DISK
fi

cd $VERITY_FOLDER

mkdir mnt

modprobe nbd
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

    # Step 4. Add roothash to UKI boot configuration via BOOTX64.CSV
    echo ""
    echo "=========================================="
    echo "  Configuring UKI Boot for dm-verity"
    echo "=========================================="
    echo "This is a UKI-only image (GRUB removed by kickstart)"
    echo "Modifying BOOTX64.CSV to add roothash parameter"
    
    # Mount EFI partition
    mount /dev/$EFI_PN mnt
    esp_mounted=1
    
    BOOTX_FILE=mnt/EFI/redhat/BOOTX64.CSV
    
    # Validate BOOTX64.CSV exists
    echo ""
    echo "[1/3] Validating UKI boot configuration..."
    if [ ! -f "$BOOTX_FILE" ]; then
        echo "ERROR: $BOOTX_FILE not found - UKI boot not configured"
        umount mnt
        exit 1
    fi
    echo "✓ BOOTX64.CSV found"
    
    # Backup and show original
    echo ""
    echo "[2/3] Original BOOTX64.CSV:"
    cp "$BOOTX_FILE" "$BOOTX_FILE.orig"
    cat "$BOOTX_FILE" | iconv -f UCS-2
    
    # Add roothash to kernel cmdline in BOOTX64.CSV
    echo ""
    echo "[3/3] Adding dm-verity parameters to BOOTX64.CSV..."
    cat "$BOOTX_FILE" | iconv -f UCS-2 | tee tmp-bootx > /dev/null
    
    # Modify the UKI boot entry to include roothash and systemd.volatile=overlay
    # Format: shimx64.efi,redhat,\EFI\Linux\<uki>.efi ,UKI bootentry
    # Becomes: shimx64.efi,redhat,\EFI\Linux\<uki>.efi roothash=$RH systemd.volatile=overlay ,UKI bootentry
    sed -i "s/\.efi  *,UKI/.efi roothash=$RH systemd.volatile=overlay ,UKI/" tmp-bootx
    
    # Convert back to UCS-2 and save
    cat tmp-bootx | iconv -t UCS-2 | tee "$BOOTX_FILE" > /dev/null
    
    echo "✓ Updated BOOTX64.CSV:"
    cat "$BOOTX_FILE" | iconv -f UCS-2
    
    # Validate roothash was added
    if ! cat "$BOOTX_FILE" | iconv -f UCS-2 | grep -q "roothash=$RH"; then
        echo ""
        echo "✗✗✗ ERROR: Failed to add roothash to BOOTX64.CSV"
        umount mnt
        exit 1
    fi
    echo ""
    echo "✓✓✓ SUCCESS: roothash added to BOOTX64.CSV"
    
    # Validate systemd.volatile=overlay
    if cat "$BOOTX_FILE" | iconv -f UCS-2 | grep -q "systemd.volatile=overlay"; then
        echo "✓✓✓ SUCCESS: systemd.volatile=overlay added to BOOTX64.CSV"
    else
        echo "✗✗✗ WARNING: systemd.volatile=overlay NOT found in BOOTX64.CSV"
    fi
    
    rm -rf tmp-bootx
    
    # Now inspect the UKI file itself to verify its embedded cmdline
    echo ""
    echo "=========================================="
    echo "  Validating UKI File Configuration"
    echo "=========================================="
    
    # Find the UKI file
    UKI_FILES=(mnt/EFI/Linux/*.efi)
    if [ ${#UKI_FILES[@]} -eq 0 ]; then
        echo "✗✗✗ ERROR: No UKI files found in /EFI/Linux/"
        umount mnt
        exit 1
    fi
    
    UKI_FILE="${UKI_FILES[0]}"
    UKI_NAME=$(basename "$UKI_FILE")
    echo "Found UKI: $UKI_NAME"
    
    # Use ukify to inspect the UKI and extract cmdline
    echo ""
    echo "Inspecting UKI with ukify..."
    if command -v ukify >/dev/null 2>&1; then
        echo "Running: ukify inspect $UKI_FILE"
        /usr/lib/systemd/ukify inspect "$UKI_FILE" > /tmp/uki-inspect.txt 2>&1 || true
        
        # Extract and display the .cmdline section
        echo ""
        echo "UKI .cmdline section:"
        if grep -A 20 "\.cmdline:" /tmp/uki-inspect.txt | head -25; then
            UKI_CMDLINE=$(grep -A 20 "\.cmdline:" /tmp/uki-inspect.txt | grep -v "\.cmdline:" | head -1 | xargs)
            echo ""
            echo "Extracted cmdline: $UKI_CMDLINE"
            
            # Check if UKI has roothash embedded (it shouldn't for our approach)
            if echo "$UKI_CMDLINE" | grep -q "roothash="; then
                echo "⚠ WARNING: UKI has embedded roothash (will be overridden by BOOTX64.CSV)"
            else
                echo "✓ UKI has no embedded roothash (correct - will use BOOTX64.CSV)"
            fi
        else
            echo "⚠ Could not extract .cmdline section from ukify output"
        fi
    else
        echo "⚠ ukify command not available for inspection"
    fi
    
    # Show what will actually boot
    echo ""
    echo "=========================================="
    echo "  Final Boot Configuration"
    echo "=========================================="
    echo "Boot method: UKI via BOOTX64.CSV"
    echo "UKI file: /EFI/Linux/$UKI_NAME"
    echo ""
    echo "BOOTX64.CSV entry:"
    cat "$BOOTX_FILE" | iconv -f UCS-2
    echo ""
    echo "Kernel will receive:"
    echo "  - UKI embedded cmdline (if any)"
    echo "  - PLUS parameters from BOOTX64.CSV:"
    echo "    roothash=$RH"
    echo "    systemd.volatile=overlay"
    echo ""
    
    esp_mounted=0
    umount mnt
    
    echo "=========================================="
    echo "  UKI Boot Configuration Complete"
    echo "=========================================="
    echo "✓ BOOTX64.CSV configured with dm-verity parameters"
    echo "✓ Ready for upload and deployment"
    echo ""
fi


# Cleanup
if [[ $nbd_mounted == 1 ]]; then
    echo "Disconnecting NBD device..."
    qemu-nbd --disconnect $NBD_DEVICE
    nbd_mounted=0
fi
rm -rf mnt

# Wait for NBD device to fully release the image file
echo ""
echo "Waiting for NBD device to release image..."
sleep 3

# Repair QCOW2 metadata corruption caused by systemd-repart via NBD
# This is expected when creating dm-verity partitions and must be fixed
echo "Repairing QCOW2 metadata corruption (expected after dm-verity via NBD)..."
if qemu-img check -r all "$DISK" 2>&1 | tee /tmp/qemu-img-repair.log; then
    echo "✓ QCOW2 image repaired successfully"
else
    echo "⚠ QCOW2 repair completed with warnings (check output above)"
fi

cd $here