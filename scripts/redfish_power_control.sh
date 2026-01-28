#!/bin/bash
set -e

# Usage: ./scripts/reboot_vm.sh [VM_INDEX] [ACTION]
# VM_INDEX: The index of the VM/Emulator (default: 0)
# ACTION: start (On), stop (ForceOff), reboot (GracefulRestart) - default: reboot

VM_INDEX=${1:-0}
ACTION=${2:-"reboot"}

# Map friendly names to Redfish ResetTypes
case "$ACTION" in
    start|On)
        RESET_TYPE="On"
        ;;
    stop|ForceOff)
        RESET_TYPE="ForceOff"
        ;;
    reboot|GracefulRestart)
        RESET_TYPE="GracefulRestart"
        ;;
    *)
        echo "Error: Invalid action '$ACTION'. Use 'start', 'stop', or 'reboot'."
        exit 1
        ;;
esac

NAMESPACE="ochami"
POD_NAME="ochami-redfish-emulator-${VM_INDEX}"

# Check for prerequisites
command -v minikube >/dev/null 2>&1 || { echo "minikube is required."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required to find a free port."; exit 1; }

echo "Targeting VM Index: $VM_INDEX (Pod: $POD_NAME)"

# Verify the pod exists
if ! minikube kubectl -- get pod -n "$NAMESPACE" "$POD_NAME" >/dev/null 2>&1; then
    echo "Error: Pod $POD_NAME not found in namespace $NAMESPACE."
    echo "Ensure you deployed with sufficient VMs: ./deploy.sh --vms $((VM_INDEX + 1))"
    exit 1
fi

# Find a free local port using Python
# This binds to port 0 (ephemeral), gets the assigned port, and closes it immediately.
LOCAL_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

echo "Selected ephemeral local port: $LOCAL_PORT"

# Start port-forward in background
PF_LOG=$(mktemp)
echo "Establishing tunnel to $POD_NAME (Log: $PF_LOG)..."
minikube kubectl -- port-forward -n "$NAMESPACE" "$POD_NAME" "$LOCAL_PORT":443 > "$PF_LOG" 2>&1 &
PF_PID=$!

# Ensure we kill the port-forward process when the script exits (success or failure)
cleanup() {
    echo "Closing tunnel (PID: $PF_PID)..."
    kill "$PF_PID" 2>/dev/null || true
    # cat "$PF_LOG" # Uncomment for debugging
    rm -f "$PF_LOG"
}
trap cleanup EXIT

# Wait for the tunnel to be ready
echo "Waiting for connection..."
MAX_RETRIES=40 # Increased to 20 seconds
COUNT=0
READY=false

while [ $COUNT -lt $MAX_RETRIES ]; do
    # Check if process died
    if ! kill -0 "$PF_PID" 2>/dev/null; then
        echo "Error: Port-forward process died."
        cat "$PF_LOG"
        exit 1
    fi

    if curl -k -s --connect-timeout 1 "https://127.0.0.1:$LOCAL_PORT/redfish/v1" >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 0.5
    COUNT=$((COUNT+1))
done

if [ "$READY" = false ]; then
    echo "Error: Timeout waiting for port-forward to become active."
    exit 1
fi

# Send the Redfish command
echo "Sending $RESET_TYPE command to https://127.0.0.1:$LOCAL_PORT/redfish/v1/Systems/1/Actions/ComputerSystem.Reset..."

HTTP_CODE=$(curl -k -s -o /dev/null -w "%{http_code}" -X POST "https://127.0.0.1:$LOCAL_PORT/redfish/v1/Systems/1/Actions/ComputerSystem.Reset" \
     -H "Content-Type: application/json" \
     -d "{\"ResetType\": \"$RESET_TYPE\"}")

if [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "204" ]; then
    echo "Success: VM $VM_INDEX ($RESET_TYPE) signal accepted."
else
    echo "Error: Failed to send command. Server returned HTTP $HTTP_CODE."
    exit 1
fi
