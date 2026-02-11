#!/bin/bash
set -e

# macOS guard: host networking setup is not needed on macOS
# (Docker Desktop / Minikube Docker driver manage their own networking)
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macOS: Skipping host network configuration."
    exit 0
fi

# Configuration
HOST_IFACE=${1:-"virbr-pxe"} # Corresponds to the bridge name defined in deploy.sh
MINIKUBE_IP=${2:-"192.168.100.2"}
CIDR=${3:-"24"}
PHY_IFACE=${4:-""}

echo "=== Configuring Network for PXE ==="
echo "Interface: $HOST_IFACE"
echo "IP Address: $MINIKUBE_IP/$CIDR"
if [ -n "$PHY_IFACE" ]; then
    echo "Physical Bridge Port: $PHY_IFACE"
fi

# Check if Minikube is running as a libvirt VM
if command -v virsh >/dev/null 2>&1 && virsh list --all --name 2>/dev/null | grep -q "^minikube$"; then
    echo "Detected Minikube running as a VM (libvirt)."

    # 1. Attach Interface (if needed)
    if ! virsh domiflist minikube | grep -q "$NET_NAME"; then
        echo "Attaching $NET_NAME interface to minikube..."
        virsh attach-interface --domain minikube --type network --source "$NET_NAME" --model virtio --config --live
        echo "Waiting for interface to initialize..."
        sleep 5
    else
        echo "Interface for $NET_NAME already attached to minikube."
    fi

    # Get the MAC address of the interface attached to pxe-net
    MAC_ADDR=$(virsh domiflist minikube | grep -w "$NET_NAME" | awk '{print $5}')
    echo "Expected MAC Address: $MAC_ADDR"

    # 2. Run configuration inside Minikube
    echo "Copying configuration script to Minikube..."
    SCRIPT_DIR=$(dirname "$0")
    chmod +x "$SCRIPT_DIR/configure_net_inside.sh"
    minikube cp "$SCRIPT_DIR/configure_net_inside.sh" /tmp/configure_net.sh

    echo "Running configuration script inside Minikube..."
    minikube ssh "sudo chmod +x /tmp/configure_net.sh && sudo /tmp/configure_net.sh $MAC_ADDR $MINIKUBE_IP"

else
    echo "Minikube VM not found. Assuming 'none' driver (host execution)."
    
    # Check if the bridge interface exists on the host
    if ip link show "$HOST_IFACE" >/dev/null 2>&1; then
        echo "Found host interface $HOST_IFACE."
        
        # Special handling for virbr-pxe: attach dummy interface to ensure carrier
        if [ "$HOST_IFACE" == "virbr-pxe" ]; then
             if ! ip link show ochami-dummy >/dev/null 2>&1; then
                 echo "Creating dummy interface ochami-dummy to keep bridge UP..."
                 sudo ip link add ochami-dummy type dummy
                 sudo ip link set ochami-dummy master "$HOST_IFACE"
                 sudo ip link set ochami-dummy up
             else
                 echo "Dummy interface ochami-dummy already exists."
                 # Ensure it is up and attached
                 sudo ip link set ochami-dummy up
                 sudo ip link set ochami-dummy master "$HOST_IFACE" 2>/dev/null || true
             fi
             
             # Bridge physical interface if provided
             if [ -n "$PHY_IFACE" ]; then
                 if ip link show "$PHY_IFACE" >/dev/null 2>&1; then
                     echo "Bridging physical interface $PHY_IFACE to $HOST_IFACE..."
                     # Ensure it's up
                     sudo ip link set dev "$PHY_IFACE" up
                     # Attach to bridge
                     sudo ip link set dev "$PHY_IFACE" master "$HOST_IFACE"
                 else
                     echo "Warning: Physical interface $PHY_IFACE specified but not found on host."
                 fi
             fi
        fi

        # Check if IP is already assigned
        if ! ip addr show "$HOST_IFACE" | grep -q "inet $MINIKUBE_IP/"; then
            echo "Adding IP $MINIKUBE_IP/$CIDR to $HOST_IFACE on host..."
            sudo ip addr add "$MINIKUBE_IP/$CIDR" dev "$HOST_IFACE"
        else
            echo "IP $MINIKUBE_IP already assigned to $HOST_IFACE."
        fi
    else
        echo "Error: Host interface $HOST_IFACE not found. Ensure the interface exists and is active."
        exit 1
    fi
fi

echo "=== Network Configuration Complete ==="
echo "Minikube is now reachable at $MINIKUBE_IP on the $NET_NAME network."