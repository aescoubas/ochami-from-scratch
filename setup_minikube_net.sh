#!/bin/bash
set -e

# Configuration
NET_NAME="pxe-net"
MINIKUBE_IP="192.168.100.2"

echo "=== Configuring Minikube Network for PXE ==="

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

echo "=== Network Configuration Complete ==="
echo "Minikube is now reachable at $MINIKUBE_IP on the $NET_NAME network."
