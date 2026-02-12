#!/bin/bash
set -e

# This script registers a physical hardware node in SMD.
# It creates the Component entry, maps the MAC address to an IP,
# registers boot parameters in BSS, and applies the boot_mac workaround.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <MAC_ADDRESS> <IP_ADDRESS> [COMPONENT_ID] [NID]"
    echo "Example: $0 00:11:22:33:44:55 192.168.50.50 x1000c0s0b0n0 1000"
    echo ""
    echo "Environment variables:"
    echo "  ORCHESTRATOR   Deployment method: minikube, quadlets, or docker-compose (default: minikube)"
    echo "  HOST_IP        Host IP for service discovery in quadlets/docker-compose mode (default: 192.168.100.2)"
    echo "  ARTIFACTS_URL  Base URL for boot artifacts (default: http://HOST_IP:HTTP_PORT/artifacts)"
    exit 1
fi

MAC_ADDRESS="$1"
IP_ADDRESS="$2"
# Default XName (Component ID) if not provided.
# Using a high number to avoid conflict with local VMs (x0c0s0b0n0)
COMPONENT_ID=${3:-"x1000c0s0b0n0"}
NID=${4:-1000}

ORCHESTRATOR=${ORCHESTRATOR:-minikube}
HOST_IP=${HOST_IP:-"192.168.100.2"}

# Validate inputs
validate_mac "$MAC_ADDRESS" "MAC address" || exit 1
validate_ip "$IP_ADDRESS" "IP address" || exit 1
validate_positive_int "$NID" "NID" || exit 1

echo "=== Registering Hardware Node ==="
echo "MAC Address:   $MAC_ADDRESS"
echo "IP Address:    $IP_ADDRESS"
echo "Component ID:  $COMPONENT_ID"
echo "NID:           $NID"
echo "Orchestrator:  $ORCHESTRATOR"

# 1. Get SMD/BSS Service IPs (orchestrator-aware)
echo "Resolving service IPs..."
if [ "$ORCHESTRATOR" == "quadlets" ] || [ "$ORCHESTRATOR" == "docker-compose" ]; then
    SMD_IP="$HOST_IP"
    BSS_IP="$HOST_IP"
else
    SMD_IP=$(minikube kubectl -- get svc ochami-smd -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    BSS_IP=$(minikube kubectl -- get svc ochami-bss -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
fi

if [ -z "$SMD_IP" ]; then
    error "Could not resolve SMD service IP. Is the deployment running?"
    exit 1
fi

echo "Using SMD Endpoint: http://${SMD_IP}:${SMD_PORT}"
echo "Using BSS Endpoint: http://${BSS_IP}:${BSS_PORT}"

# 2. Create Component (Node)
echo "Creating Node Component..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${SMD_IP}:${SMD_PORT}/hsm/v2/State/Components" \
  -H "Content-Type: application/json" \
  -d "{
    \"Components\": [{
      \"ID\": \"${COMPONENT_ID}\",
      \"Type\": \"Node\",
      \"State\": \"On\",
      \"Flag\": \"OK\",
      \"Role\": \"Compute\",
      \"NID\": ${NID},
      \"NetType\": \"Sling\"
    }]
  }")

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    echo "  -> Success ($HTTP_CODE)"
else
    echo "  -> Failed ($HTTP_CODE). Node might already exist or service is unreachable."
fi

# 3. Create EthernetInterface
echo "Mapping MAC to IP..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://${SMD_IP}:${SMD_PORT}/hsm/v2/Inventory/EthernetInterfaces" \
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

# 4. Register Boot Parameters in BSS
if [ -z "$BSS_IP" ]; then
    warn "Could not resolve BSS service IP. Skipping boot parameter registration."
else
    echo "Registering boot parameters in BSS for $COMPONENT_ID..."

    ARTIFACTS_URL="${ARTIFACTS_URL:-http://${HOST_IP}:${HTTP_PORT}/artifacts}"

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://${BSS_IP}:${BSS_PORT}/boot/v1/bootparameters" \
      -H "Content-Type: application/json" \
      -d "{
        \"hosts\": [\"${COMPONENT_ID}\"],
        \"macs\": [\"${MAC_ADDRESS}\"],
        \"kernel\": \"${ARTIFACTS_URL}/vmlinuz-lts\",
        \"initrd\": \"${ARTIFACTS_URL}/initramfs-lts\",
        \"params\": \"console=ttyS0 ip=dhcp rd.neednet=1 root=live:${ARTIFACTS_URL}/rootfs.squashfs\"
      }")

    if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
        echo "  -> Success ($HTTP_CODE)"
    else
        echo "  -> Failed ($HTTP_CODE)."
    fi

    # 5. Apply boot_mac + nid database workaround
    # BSS API doesn't properly save boot_mac or nid in the nodes table.
    # Without boot_mac, BSS can't look up boot params by MAC.
    # Without nid, BSS treats the node as unknown/disabled.
    echo "Applying BSS nodes table workaround (boot_mac + nid)..."
    UPDATE_CMD="psql -U ${BSS_DB_USER} -d ${BSS_DB_NAME} -c \"UPDATE nodes SET boot_mac = '${MAC_ADDRESS}', nid = ${NID} WHERE xname = '${COMPONENT_ID}';\""

    if [ "$ORCHESTRATOR" == "docker-compose" ]; then
        PG_CONTAINER=$(docker ps --format "{{.Names}}" | grep postgres | head -n 1)
        if [ -n "$PG_CONTAINER" ]; then
            if docker exec "$PG_CONTAINER" bash -c "$UPDATE_CMD" >/dev/null 2>&1; then
                echo "  -> Database updated successfully (Docker Compose)."
            else
                echo "  -> Warning: Failed to update database (Docker Compose). Boot might fail."
            fi
        else
            echo "  -> Warning: Postgres container not found (Docker Compose). Boot might fail."
        fi
    elif [ "$ORCHESTRATOR" == "quadlets" ]; then
        PG_CONTAINER=$(sudo podman ps --format "{{.Names}}" | grep postgres | head -n 1)
        if [ -n "$PG_CONTAINER" ]; then
            if sudo podman exec "$PG_CONTAINER" bash -c "$UPDATE_CMD" >/dev/null 2>&1; then
                echo "  -> Database updated successfully (Quadlets)."
            else
                echo "  -> Warning: Failed to update database (Quadlets). Boot might fail."
            fi
        else
            echo "  -> Warning: Postgres container not found (Quadlets). Boot might fail."
        fi
    else
        if minikube kubectl -- exec -n ochami ochami-postgres -- bash -c "$UPDATE_CMD" >/dev/null 2>&1; then
            echo "  -> Database updated successfully (Minikube)."
        else
            echo "  -> Warning: Failed to update database (Minikube). Boot might fail."
        fi
    fi
fi

echo ""
echo "Registration complete for $COMPONENT_ID."
echo "The node should now boot successfully on the next PXE cycle."
