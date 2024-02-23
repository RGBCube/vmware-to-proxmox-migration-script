#!/bin/bash

### PREREQUISITES ###
# - Install ovftool on the Proxmox host - https://developer.vmware.com/web/tool/ovf/
# - Hardcode the variables for your ESXi IP, user, etc.

# Gets user input, returns the default value if no input was provided.
# Doesn't prompt if the variable is already set.
# Accepts a validation regex too.
#
# Usage:
#
# input BROADCOM_HATE_LEVEL "The amount you hate broadcom" "infinite" "^(none|somewhat|a lot|infinite)$"
function input() {
    local prompt="$2"
    local default="$3"
    local validation_regex="$4"

    if [[ -z "${!1}" ]]; then
        read -p "($1) $prompt [${default:-required}]: " "$1"
    fi

    if [[ -z "${!1}" ]] && [[ -z "$default" ]]; then
        echo "Error: Configuration variable '$1' is required."
        input "$@"
    fi

    if [[ -n "$validation_regex" ]] && [[ ! "${!1}" =~ $validation_regex ]]; then
        echo "Error: Invalid value for '$1'. Must match validation regex '$validation_regex'."
        unset "$1"
        input "$@"
    fi
}

# Checks for the availability of the passed in commands,
# exits with a message if at least one is not available.
function require() {
    local missing=()

    for command in "$@"; do
        if ! type "$command" &> /dev/null; then
            missing+=("$command")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "Error: The following commands that are required to run this script are not in PATH:"

        for command in "${missing[@]}"; do
            echo "- $command"
        done

        echo "Please install them and try again."
        exit 1
    fi
}

require qm ovftool jq virt-customize

input ESXI_SERVER "ESXi server hostname/IP"
input ESXI_USERNAME "ESXi server username"
input ESXI_PASSWORD "ESXi server password"

input VM_NAME "Same of the VM to migrate"
input VLAN_TAG "VLAN tag" "80"

while [[ true ]]; do
    input VM_ID "VM ID you would like to use in Proxmox (must be bigger than 99)" "" "^[0-9]{3,}$"

    # Check if a VM with the given ID already exists before proceeding
    if qm status "$VM_ID" &> /dev/null; then
        echo "Error: VM with ID '$VM_ID' already exists. Please enter a different ID."
        unset VM_ID
    else
        break
    fi
done

input STORAGE_TYPE "Storage type (local-lvm or local-zfs)" "local-lvm" "^local-lvm|local-zfs\$"

function export-vmware-vm() {
    #local ova_file="/var/vm-migration/$VM_NAME.ova"
    local ova_file="/mnt/vm-migration/$VM_NAME.ova"

    if [ -f "$ova_file" ]; then
        local choice
        input choice "File '$ova_file' already exists. Overwrite? (y/n)" "y" "^y|n$"

        if [[ "$choice" == "n" ]]; then
            echo "Export cancelled."
            exit 1
        fi

        rm "$ova_file"
    fi

    echo "Exporting VM from VMware directly to Proxmox..."
    echo $ESXI_PASSWORD | ovftool \
        --sourceType=VI \
        --acceptAllEulas \
        --noSSLVerify \
        --skipManifestCheck \
        --diskMode=thin \
        "--name=$VM_NAME" \
        "vi://$ESXI_USERNAME@$ESXI_SERVER/$VM_NAME" \
        "$ova_file"
}

function get-firmware-type() {
    local vmx_path="/vmfs/volumes/datastore/${VM_NAME}/${VM_NAME}.vmx"
    local type=$(sshpass -p "${ESXI_PASSWORD}" ssh -o StrictHostKeyChecking=no ${ESXI_USERNAME}@${ESXI_SERVER} "grep 'firmware =' ${vmx_path}")

    if [[ "$type" =~ "efi" ]]; then
        echo "uefi"
    else
        echo "seabios"
    fi
}

function create-proxmox-vm() {
    echo "Extracting OVF from OVA..."

    tar -xvf "/mnt/vm-migration/$VM_NAME.ova" -C /mnt/vm-migration/

    echo "Searching for .vmdk file..."
    local ovf_file=$(find /mnt/vm-migration -name '*.ovf')
    echo "Found OVF file: '$ovf_file'"

    echo "Searching for .vmdk file..."
    local vmdk_file=$(find /mnt/vm-migration -name "$VM_NAME-disk*.vmdk")
    echo "Found .vmdk file: '$vmdk_file'"

    # Ensure that only one .vmdk file is found
    if [[ $(echo "$vmdk_file" | wc -l) != 1 ]]; then
       echo "Error: Multiple or no .vmdk files found."
       exit 1
    fi

    local raw_file="$VM_NAME.raw"
    local raw_path="/mnt/vm-migration/$raw_file"
    echo "Converting .vmdk file to raw format..."
    qemu-img convert -f vmdk -O raw "$vmdk_file" "$raw_path"
    echo "Converted .vmdk file to raw format!"

    # Install qemu-guest-agent using virt-customize
    echo "Installing qemu-guest-agent using virt-customize..."
    virt-customize -a "$raw_path" --install qemu-guest-agent || {
        echo "Failed to install qemu-guest-agent."
        exit 1
    }
    echo "Installed qemu-guest-agent used virt-customize!"

    FIRMWARE_TYPE=$(get-firmware-type)

    # Create the VM and set various options such as BIOS type.
    echo "Creating VM in Proxmox with $FIRMWARE_TYPE firmware, VLAN tag, and SCSI hardware..."
    qm create $VM_ID --name "$VM_NAME" --memory 2048 --cores 2 --net0 "virtio,bridge=vmbr0,tag=$VLAN_TAG" --bios "$FIRMWARE_TYPE" --scsihw virtio-scsi-pci
    echo "Created VM in Proxmox with $FIRMWARE_TYPE firmware, VLAN tag, and SCSI hardware!"

    echo "Enabling QEMU Guest Agent..."
    qm set $VM_ID --agent 1
    echo "Enabled QEMU Guest Agent!"

    echo "Importing disk to $STORAGE_TYPE storage..."
    qm importdisk "$VM_ID" "$raw_path" "$STORAGE_TYPE"
    echo "Imported disk to $STORAGE_TYPE storage!"

    local disk_name="vm-$VM_ID-disk-0"
    echo "Attaching disk to VM and setting it as the first boot device..."
    qm set "$VM_ID" --scsi0 "$STORAGE_TYPE:$disk_name" --boot c --bootdisk scsi0
    echo "Attached disk to VM and setted it as the first boot device!"

    echo "Enabling discard functionality..."
    qm set "$VM_ID" --scsi0 "$STORAGE_TYPE:$disk_name,discard=on"
    echo "Enabled discard functionality!"
}

function clean-migration-directory() {
    echo "Cleaning up /mnt/vm-migration directory..."
    rm -rf /mnt/vm-migration/*
    echo "Cleaned up /mnt/vm-migration directory!"
}

# Add an EFI disk to the VM after all other operations have concluded
function add-efi-disk-to-vm() {
    echo "Adding EFI disk to the VM..."
    local vg_name="pve" # The actual LVM volume group name
    local efi_disk_size="4M"
    local efi_disk="vm-$VM_ID-disk-1"

    # Create the EFI disk as a logical volume
    echo "Creating EFI disk as a logical volume..."
    lvcreate -L "$efi_disk_size" -n "$efi_disk" "$vg_name" || {
        echo "Failed to create EFI disk logical volume."
        exit 1
    }
    echo "Created EFI disk as a logical volume!"

    # Attach the EFI disk to the VM
    echo "Attaching EFI disk to VM..."
    qm set "$VM_ID" --efidisk0 "$STORAGE_TYPE:$efi_disk,size=$efi_disk_size,efitype=4m,pre-enrolled-keys=1" || {
        echo "Failed to add EFI disk to VM."
        exit 1
    }
    echo "Attached EFI disk to VM!"

    echo "Added EFI disk to the VM!"
}

# === Main Process ===
export-vmware-vm
create-proxmox-vm
cleanup-migration-directory

if [ "$FIRMWARE_TYPE" == "uefi" ]; then # FIRMWARE_TYPE was set in create-proxmox-vm
    add-efi-disk-to-vm
else
    echo "Skipping EFI disk creation for non-UEFI firmware type."
fi
