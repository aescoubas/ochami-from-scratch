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

# 5. Register Redfish Endpoint (BMC)
# Extract index from VM Name (assuming format ends in numbers, e.g., virtual-compute-node-0)
VM_INDEX=$(echo "$VM_NAME" | grep -oE '[0-9]+$' || true)

if [ -n "$VM_INDEX" ]; then
    # Derive BMC ID from Node ID (e.g., x0c0s0b0n0 -> x0c0s0b0)
    BMC_ID=${COMPONENT_ID%n*}
    
    # Construct Pod Name
    POD_NAME="ochami-redfish-emulator-${VM_INDEX}"
    NAMESPACE="ochami"
    
    echo "Fetching IP for emulator pod '$POD_NAME'..."
    EMULATOR_IP=$(minikube kubectl -- get pod -n "$NAMESPACE" "$POD_NAME" -o jsonpath='{.status.podIP}' 2>/dev/null)
    
    if [ -n "$EMULATOR_IP" ]; then
        echo "Registering BMC ($BMC_ID) for Emulator $VM_INDEX..."
        echo "  IP: $EMULATOR_IP"
        
        # Register endpoint. 
        # RediscoverOnUpdate=true triggers SMD to immediately query the emulator.
        
        # Try POST first
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${SMD_IP}:27779/hsm/v2/Inventory/RedfishEndpoints" \
          -H "Content-Type: application/json" \
          -d "{ 
            \"ID\": \"${BMC_ID}\", 
            \"RediscoverOnUpdate\": true, 
            \"Hostname\": \"${EMULATOR_IP}\", 
            \"User\": \"root\", 
            \"Password\": \"password\" 
          }")
          
        if [ "$HTTP_CODE" -eq 409 ]; then
             echo "  -> Endpoint exists (409). Updating via PUT to trigger rediscovery..."
             curl -s -X PUT "http://${SMD_IP}:27779/hsm/v2/Inventory/RedfishEndpoints/${BMC_ID}" \
              -H "Content-Type: application/json" \
              -d "{ 
                \"ID\": \"${BMC_ID}\", 
                \"RediscoverOnUpdate\": true, 
                \"Hostname\": \"${EMULATOR_IP}\", 
                \"User\": \"root\", 
                \"Password\": \"password\" 
              }" > /dev/null
        elif [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
             echo "  -> Created ($HTTP_CODE)"
        else
             echo "  -> Failed ($HTTP_CODE)"
        fi
    else
        echo "Warning: Could not find IP for pod '$POD_NAME'. Skipping BMC registration."
    fi
else
    echo "Warning: Could not extract VM index from '$VM_NAME'. Skipping BMC registration."
fi

# 6. Register Boot Parameters in BSS
echo "Fetching BSS service IP..."
BSS_IP=$(minikube kubectl -- get svc ochami-bss -n ochami -o jsonpath='{.spec.clusterIP}')
if [ -z "$BSS_IP" ]; then
    echo "Warning: Could not find BSS service IP. Skipping boot parameter registration."
else
    echo "BSS IP: $BSS_IP"
    echo "Registering default boot parameters in BSS for $COMPONENT_ID..."
    
    # Artifacts URL base (assumes default setup on 192.168.100.2:30080)
    # Ideally this should be dynamic, but for this script we match the default deployment.
    ARTIFACTS_URL="${ARTIFACTS_URL:-http://192.168.100.2:30080/artifacts}"
    
    curl -s -X PUT "http://${BSS_IP}:27778/boot/v1/bootparameters" \
      -H "Content-Type: application/json" \
      -d "{
        \"hosts\": [\"${COMPONENT_ID}\"],
        \"macs\": [\"${MAC}\"],
        \"kernel\": \"${ARTIFACTS_URL}/vmlinuz-lts\",
        \"initrd\": \"${ARTIFACTS_URL}/initramfs-lts\",
        \"params\": \"console=ttyS0 ip=dhcp rd.neednet=1 root=live:${ARTIFACTS_URL}/rootfs.squashfs\"
      }" > /dev/null
      
    echo "Boot parameters registered."
fi

echo ""
echo "Registration complete for $VM_NAME ($COMPONENT_ID)."
echo "You can now restart the VM to boot into production mode:"
echo "  sudo virsh destroy $VM_NAME"
echo "  sudo virsh start --console $VM_NAME"
