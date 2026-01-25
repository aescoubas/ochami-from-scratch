#!/bin/bash
set -e

# This script registers a VM (or node) in SMD to transition it from discovery mode to production mode.

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <VM_NAME> <IP_ADDRESS>"
    echo "Example: $0 virtual-compute-node 192.168.100.50"
    exit 1
fi

VM_NAME="$1"
IP_ADDRESS="$2"

# 1. Get MAC address from the VM
echo "Fetching MAC address for '$VM_NAME' நான"
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
echo "Registering Node component in SMD..."
curl -s -X POST "http://${SMD_IP}:27779/hsm/v2/State/Components" \
  -H "Content-Type: application/json" \
  -d '{ "Components": [{ "ID": "x0c0s0b0n0", "Type": "Node", "State": "On", "Flag": "OK", "Role": "Compute", "NID": 1, "NetType": "Sling" }] }' > /dev/null

# 4. Create EthernetInterface
echo "Registering EthernetInterface ($IP_ADDRESS)..."
curl -s -X POST "http://${SMD_IP}:27779/hsm/v2/Inventory/EthernetInterfaces" \
  -H "Content-Type: application/json" \
  -d "{ \"Description\": \"Node NIC\", \"MACAddress\": \"${MAC}\", \"IPAddresses\": [{\"IPAddress\": \"${IP_ADDRESS}\"}], \"ComponentID\": \"x0c0s0b0n0\" }" > /dev/null

echo ""
echo "Registration complete."
echo "You can now restart the VM to boot into production mode:"
echo "  sudo virsh destroy $VM_NAME"
echo "  sudo virsh start --console $VM_NAME"
