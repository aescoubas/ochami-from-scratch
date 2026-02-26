#!/bin/bash
set -e

# Configuration
NUM_VMS=2
HOST_IP="192.168.100.2"
ARTIFACTS_URL="http://$HOST_IP:30080/artifacts/opensuse"

export ARTIFACTS_URL

echo "Recreating $NUM_VMS VMs..."

# Start assigning static IPs for registered nodes from .50
CURRENT_IP_OCTET=50

for i in $(seq 0 $((NUM_VMS - 1))); do
    VM_NAME="virtual-compute-node-$i"
    # Format: x0c0s{i}b0n0
    COMP_ID="x0c0s${i}b0n0"
    STATIC_IP="192.168.100.${CURRENT_IP_OCTET}"
    # Fixed MAC: 52:54:00:00:00:0{i+1}
    FIXED_MAC="52:54:00:00:00:0$((i+1))"
    
    echo "Processing $VM_NAME..."
    
    # Check if VM exists and destroy it
    if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        echo "Destroying existing VM $VM_NAME..."
        sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
        sudo virsh undefine --nvram "$VM_NAME" >/dev/null 2>&1 || true
    fi
    
    echo "Creating $VM_NAME..."
    sudo ./scripts/create_vm.sh --name "$VM_NAME" --mac "$FIXED_MAC"
    
    echo "Registering $VM_NAME ($COMP_ID) with IP $STATIC_IP..."
    sleep 2
    
    # Register
    ./scripts/register_local_vm.sh "$VM_NAME" "$STATIC_IP" "$COMP_ID" "$((i+1))" || echo "Warning: Registration failed for $VM_NAME"

    CURRENT_IP_OCTET=$((CURRENT_IP_OCTET + 1))
    
    # Reboot to force PXE
    echo "Restarting $VM_NAME to pick up new configuration..."
    sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
done

echo "VMs recreated and registered."
