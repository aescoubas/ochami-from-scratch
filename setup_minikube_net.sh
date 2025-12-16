#!/bin/bash
set -e

# Configuration
NET_NAME="pxe-net"
MINIKUBE_IP="192.168.100.2"
HOST_IFACE="virbr-pxe" # Corresponds to the bridge name defined in deploy.sh

echo "=== Configuring Minikube Network for PXE ==="

# Check if Minikube is running as a libvirt VM
if virsh list --all --name | grep -q "^minikube$"; then
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
    chmod +x configure_net_inside.sh
    minikube cp configure_net_inside.sh /tmp/configure_net.sh

    echo "Running configuration script inside Minikube..."
    minikube ssh "sudo chmod +x /tmp/configure_net.sh && sudo /tmp/configure_net.sh $MAC_ADDR $MINIKUBE_IP"

else
    echo "Minikube VM not found. Assuming 'none' driver (host execution)."
    
    # Check if the bridge interface exists on the host
    if ip link show "$HOST_IFACE" >/dev/null 2>&1; then
        echo "Found host interface $HOST_IFACE."
        
        # Check if IP is already assigned
        if ! ip addr show "$HOST_IFACE" | grep -q "inet $MINIKUBE_IP/"; then
            echo "Adding IP $MINIKUBE_IP to $HOST_IFACE on host..."
            sudo ip addr add "$MINIKUBE_IP/24" dev "$HOST_IFACE"
        else
            echo "IP $MINIKUBE_IP already assigned to $HOST_IFACE."
        fi
    else
        echo "Error: Host interface $HOST_IFACE not found. Ensure pxe-net is active (check deploy.sh network creation)."
        exit 1
    fi
fi

echo "=== Network Configuration Complete ==="
echo "Minikube is now reachable at $MINIKUBE_IP on the $NET_NAME network."