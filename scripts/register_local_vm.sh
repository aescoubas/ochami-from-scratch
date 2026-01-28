#!/bin/bash
set -e

# This script registers a VM (or node) in SMD to transition it from discovery mode to production mode.

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <VM_NAME> <IP_ADDRESS> [COMPONENT_ID] [NID]"
    echo "Example: $0 virtual-compute-node-0 192.168.100.50 x0c0s0b0n0 1"
    exit 1
fi

VM_NAME="$1"
IP_ADDRESS="$2"
COMPONENT_ID="${3:-x0c0s0b0n0}"
NID="${4:-1}"

# 1. Get MAC address from the VM
echo "Fetching MAC address for '$VM_NAME'..."
MAC=$(sudo virsh domiflist "$VM_NAME" | awk '/pxe-net/ {print $5}')

if [ -z "$MAC" ]; then
    echo "Error: Could not find MAC address for VM '$VM_NAME' on network 'pxe-net'."
    exit 1
fi

echo "Found MAC: $MAC"

# 2. Get SMD Service IP
echo "Fetching SMD service IP..."
SMD_IP=$(minikube kubectl -- get svc ochami-smd -n ochami -o jsonpath='{.spec.clusterIP}')
if [ -z "$SMD_IP" ]; then
    echo "Error: Could not find SMD service IP."
    exit 1
fi
echo "SMD IP: $SMD_IP"

# 3. Create Component (Node)
echo "Registering Node component in SMD (ID: $COMPONENT_ID, NID: $NID)..."
curl -s -X POST "http://${SMD_IP}:27779/hsm/v2/State/Components" \
  -H "Content-Type: application/json" \
  -d "{ \"Components\": [{ \"ID\": \"${COMPONENT_ID}\", \"Type\": \"Node\", \"State\": \"On\", \"Flag\": \"OK\", \"Role\": \"Compute\", \"NID\": ${NID}, \"NetType\": \"Sling\" }] }" > /dev/null

# 4. Create EthernetInterface
echo "Registering EthernetInterface ($IP_ADDRESS) for $COMPONENT_ID..."
curl -s -X POST "http://${SMD_IP}:27779/hsm/v2/Inventory/EthernetInterfaces" \
  -H "Content-Type: application/json" \
  -d "{ \"Description\": \"Node NIC\", \"MACAddress\": \"${MAC}\", \"IPAddresses\": [{\"IPAddress\": \"${IP_ADDRESS}\"}], \"ComponentID\": \"${COMPONENT_ID}\" }" > /dev/null

echo ""
echo "Registration complete for $VM_NAME ($COMPONENT_ID)."
echo "You can now restart the VM to boot into production mode:"
echo "  sudo virsh destroy $VM_NAME"
echo "  sudo virsh start --console $VM_NAME"
