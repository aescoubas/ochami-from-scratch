#!/bin/bash

set -e

# This script creates a new Libvirt VM for the OpenCHAMI minimal tutorial.

# --- Configuration ---
VM_NAME="virtual-compute-node"
MEMORY="2048" # in MiB
VCPUS="1"
# ---

echo "Checking for existing VM..."
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "VM '$VM_NAME' already exists. To recreate it, first destroy and undefine it:"
  echo "  sudo virsh destroy $VM_NAME"
  echo "  sudo virsh undefine --nvram $VM_NAME"
  exit 1
fi

virsh net-uuid pxe-net >/dev/null 2>&1 || virsh net-define <(cat <<EOF
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

echo "Creating VM '$VM_NAME' with virt-install..."

virt-install \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --vcpus "$VCPUS" \
  --disk none \
  --network network=pxe-net,model=virtio \
  --os-variant centos-stream9 \
  --graphics none \
  --console pty,target_type=serial \
  --pxe \
  --boot network,hd \
  --virt-type kvm \
  --noautoconsole

echo "VM '$VM_NAME' created successfully."
echo ""

echo "Fetching MAC address..."
MAC_ADDRESS=$(sudo virsh domiflist "$VM_NAME" | awk '/pxe-net/ {print $5}')

echo "========================================================================"
echo "VM MAC Address: $MAC_ADDRESS"
echo "========================================================================"
echo ""
echo "You can now use this MAC address to configure OpenCHAMI as described in the README.md."
echo "To start the VM and connect to the console, run:"
echo "  sudo virsh start --console $VM_NAME"
