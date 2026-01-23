#!/bin/bash

set -e

# This script creates a new Libvirt VM for the OpenCHAMI minimal tutorial.
# Supports both BIOS (Legacy) and UEFI boot modes for PXE testing.

# --- Configuration ---
VM_NAME="virtual-compute-node"
MEMORY="2048" # in MiB
VCPUS="1"
BOOT_MODE="bios"  # Default: bios (legacy). Options: bios, uefi

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --name) VM_NAME="$2"; shift ;;
        --memory) MEMORY="$2"; shift ;;
        --vcpus) VCPUS="$2"; shift ;;
        --uefi) BOOT_MODE="uefi" ;;
        --bios) BOOT_MODE="bios" ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --name NAME     VM name (default: virtual-compute-node)"
            echo "  --memory MiB    Memory in MiB (default: 2048)"
            echo "  --vcpus N       Number of vCPUs (default: 1)"
            echo "  --bios          Use BIOS/Legacy boot (default)"
            echo "  --uefi          Use UEFI boot"
            echo "  -h, --help      Show this help"
            echo ""
            echo "The VM will PXE boot from the pxe-net network."
            echo "BIOS mode uses SeaBIOS with undionly.kpxe from TFTP."
            echo "UEFI mode uses OVMF with ipxe.efi from TFTP."
            exit 0
            ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done
# ---

echo "Creating VM: $VM_NAME"
echo "  Memory: ${MEMORY} MiB"
echo "  vCPUs: $VCPUS"
echo "  Boot mode: $BOOT_MODE"
echo ""

echo "Checking for existing VM..."
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "VM '$VM_NAME' already exists. To recreate it, first destroy and undefine it:"
  echo "  sudo virsh destroy $VM_NAME"
  echo "  sudo virsh undefine --nvram $VM_NAME"
  exit 1
fi

virsh net-uuid pxe-net >/dev/null 2>&1 || {
virsh net-define <(cat <<EOF
<network>
  <name>pxe-net</name>
  <uuid>c8f874f7-dd7a-465c-862a-ec30f41ac4bb</uuid>
  <bridge name='virbr-pxe' stp='on' delay='0'/>
  <mac address='52:54:00:d8:3f:37'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
  </ip>
</network>
EOF
)
virsh net-start pxe-net
virsh net-autostart pxe-net
}

echo "Creating VM '$VM_NAME' with virt-install..."

# Build virt-install command based on boot mode
VIRT_INSTALL_ARGS=(
  --name "$VM_NAME"
  --memory "$MEMORY"
  --vcpus "$VCPUS"
  --disk none
  --network network=pxe-net,model=virtio
  --os-variant centos-stream9
  --graphics none
  --console pty,target_type=serial
  --pxe
  --virt-type kvm
  --noautoconsole
)

if [ "$BOOT_MODE" = "uefi" ]; then
  echo "Using UEFI boot mode (OVMF firmware)..."
  # UEFI boot requires OVMF firmware and --boot uefi
  VIRT_INSTALL_ARGS+=(
    --boot uefi,network
  )
else
  echo "Using BIOS boot mode (SeaBIOS)..."
  # Standard BIOS/Legacy boot
  VIRT_INSTALL_ARGS+=(
    --boot network,hd
  )
fi

virt-install "${VIRT_INSTALL_ARGS[@]}"

echo "VM '$VM_NAME' created successfully."
echo ""

echo "Fetching MAC address..."
MAC_ADDRESS=$(virsh domiflist "$VM_NAME" | awk '/pxe-net/ {print $5}')

echo "========================================================================"
echo "VM Configuration:"
echo "  Name:       $VM_NAME"
echo "  MAC Address: $MAC_ADDRESS"
echo "  Boot Mode:   $BOOT_MODE"
echo "========================================================================"
echo ""
echo "PXE Boot Flow ($BOOT_MODE):"
if [ "$BOOT_MODE" = "uefi" ]; then
  echo "  1. OVMF firmware sends DHCP request"
  echo "  2. CoreDHCP responds with TFTP server + ipxe.efi filename"
  echo "  3. Firmware downloads ipxe.efi via TFTP"
  echo "  4. iPXE sends DHCP request (identifies as iPXE client)"
  echo "  5. CoreDHCP responds with HTTP boot script URL"
  echo "  6. iPXE downloads boot.ipxe and boots kernel/initrd"
else
  echo "  1. SeaBIOS PXE ROM sends DHCP request"
  echo "  2. CoreDHCP responds with TFTP server + undionly.kpxe filename"
  echo "  3. PXE ROM downloads undionly.kpxe via TFTP"
  echo "  4. iPXE sends DHCP request (identifies as iPXE client)"
  echo "  5. CoreDHCP responds with HTTP boot script URL"
  echo "  6. iPXE downloads boot.ipxe and boots kernel/initrd"
fi
echo ""
echo "To start the VM and connect to the console, run:"
echo "  sudo virsh start --console $VM_NAME"
