#!/bin/bash
set -e

# This script registers a physical hardware node in SMD.
# It creates the Component entry, maps the MAC address to an IP,
# registers boot parameters in BSS, and applies the boot_mac workaround.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if [ "$#" -lt 7 ]; then
    echo "Usage: $0 <MAC_ADDRESS> <IP_ADDRESS> <COMPONENT_ID> <NID> <BMC_IP> <BMC_USER> <BMC_PASS>"
    echo "Example: $0 00:11:22:33:44:55 192.168.50.50 x1000c0s0b0n0 1000 192.168.50.100 root password"
    echo ""
    echo "Environment variables:"
    echo "  ORCHESTRATOR   Deployment method: minikube, quadlets, or docker-compose (default: minikube)"
    echo "  HOST_IP        Host IP for service discovery in quadlets/docker-compose mode (default: 192.168.100.2)"
    echo "  ARTIFACTS_URL  Base URL for boot artifacts (default: http://HOST_IP:HTTP_PORT/artifacts)"
    exit 1
fi

MAC_ADDRESS="$1"
IP_ADDRESS="$2"
COMPONENT_ID="$3"
NID="$4"
BMC_IP="$5"
BMC_USER="$6"
BMC_PASS="$7"

ORCHESTRATOR=${ORCHESTRATOR:-minikube}
HOST_IP=${HOST_IP:-"192.168.100.2"}
BMC_XNAME="${COMPONENT_ID%n[0-9]*}"

# Validate inputs
validate_mac "$MAC_ADDRESS" "MAC address" || exit 1
validate_ip "$IP_ADDRESS" "IP address" || exit 1
validate_positive_int "$NID" "NID" || exit 1
validate_ip "$BMC_IP" "BMC IP" || exit 1

echo "=== Registering Hardware Node ==="
echo "MAC Address:   $MAC_ADDRESS"
echo "IP Address:    $IP_ADDRESS"
echo "Component ID:  $COMPONENT_ID"
echo "NID:           $NID"
echo "BMC IP:        $BMC_IP"
echo "BMC XName:     $BMC_XNAME"
echo "BMC User:      $BMC_USER"
echo "Orchestrator:  $ORCHESTRATOR"

echo "Resolving service IPs..."
read -r SMD_IP BSS_IP < <(resolve_service_endpoints "$HOST_IP" "$ORCHESTRATOR") || exit 1
echo "Using SMD Endpoint: http://${SMD_IP}:${SMD_PORT}"
echo "Using BSS Endpoint: http://${BSS_IP}:${BSS_PORT}"

register_hardware_node_with_endpoints \
    "$MAC_ADDRESS" "$IP_ADDRESS" "$COMPONENT_ID" "$NID" "$BMC_IP" "$BMC_USER" "$BMC_PASS" \
    "$SMD_IP" "$BSS_IP" "$HOST_IP" "$ORCHESTRATOR" "$COMPONENT_ID"

echo ""
echo "Registration complete for $COMPONENT_ID."
echo "The node should now boot successfully on the next PXE cycle."
