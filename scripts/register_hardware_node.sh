#!/bin/bash
set -e

# This script registers a physical hardware node in SMD.
# It creates the Component entry and maps the MAC address to an IP.

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <MAC_ADDRESS> <IP_ADDRESS> [COMPONENT_ID]"
    echo "Example: $0 00:11:22:33:44:55 192.168.50.50 x1000c0s0b0n0"
    exit 1
fi

MAC_ADDRESS="$1"
IP_ADDRESS="$2"
# Default XName (Component ID) if not provided. 
# Using a high number to avoid conflict with local VMs (x0c0s0b0n0)
COMPONENT_ID=${3:-"x1000c0s0b0n0"}

echo "=== Registering Hardware Node ==="
echo "MAC Address:  $MAC_ADDRESS"
echo "IP Address:   $IP_ADDRESS"
echo "Component ID: $COMPONENT_ID"

# 1. Get SMD Service IP
echo "Fetching SMD service IP..."
# Try to get it from Minikube first
if command -v minikube >/dev/null 2>&1; then
    SMD_IP=$(minikube kubectl -- get svc ochami-smd -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
fi

# Fallback or override if needed
if [ -z "$SMD_IP" ]; then
    echo "Warning: Could not fetch SMD IP from Minikube. Is Minikube running?"
    echo "Enter SMD IP/Hostname manually (e.g., localhost, 192.168.100.2): "
    read -r SMD_IP
fi
echo "Using SMD Endpoint: http://${SMD_IP}:27779"

# 2. Create Component (Node)
echo "Creating Node Component..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${SMD_IP}:27779/hsm/v2/State/Components" \
  -H "Content-Type: application/json" \
  -d '{
    "Components": [{
      "ID": "'$COMPONENT_ID'",
      "Type": "Node",
      "State": "On",
      "Flag": "OK",
      "Role": "Compute",
      "NID": 1000,
      "NetType": "Sling"
    }]
  }')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "  -> Success ($HTTP_CODE)"
else
    echo "  -> Failed ($HTTP_CODE). Node might already exist or service is unreachable."
fi

# 3. Create EthernetInterface
echo "Mapping MAC to IP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${SMD_IP}:27779/hsm/v2/Inventory/EthernetInterfaces" \
  -H "Content-Type: application/json" \
  -d "{
    \"Description\": \"Physical Node NIC\",
    \"MACAddress\": \"${MAC_ADDRESS}\",
    \"IPAddresses\": [{\"IPAddress\": \"${IP_ADDRESS}\"}],
    \"ComponentID\": \"${COMPONENT_ID}\" 
  }")

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "  -> Success ($HTTP_CODE)"
else
    echo "  -> Failed ($HTTP_CODE). Interface might already exist."
fi

echo ""
echo "Registration Complete."
echo "The node should now boot successfully on the next PXE cycle."
