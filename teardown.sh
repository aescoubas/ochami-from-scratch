#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Parse arguments
REMOVE_IMAGES=false
for arg in "$@"; do
    case $arg in
        --remove-images)
        REMOVE_IMAGES=true
        shift
        ;;
    esac
done

echo -e "${RED}=== OpenCHAMI Teardown Script ===${NC}"
echo "This script will PERMANENTLY DELETE:"
echo "  - VM: virtual-compute-node"
echo "  - Network: pxe-net"
echo "  - Minikube Cluster"
echo "  - Build Artifacts (kernels, initramfs)"
if [ "$REMOVE_IMAGES" = true ]; then
    echo "  - Docker Images (ochami related) [ENABLED]"
else
    echo "  - Docker Images (ochami related) [SKIPPED - use --remove-images to delete]"
fi
echo ""

read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# 1. Destroy VM (Requires sudo as it was created with sudo)
VM_NAME="virtual-compute-node"
echo -e "${GREEN}--> Removing VM '$VM_NAME' (may ask for sudo password)...${NC}"
if sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    sudo virsh undefine --nvram "$VM_NAME"
    echo "VM removed."
else
    echo "VM '$VM_NAME' not found (or access denied)."
fi

# 2. Destroy Network
NET_NAME="pxe-net"
echo -e "${GREEN}--> Removing Network '$NET_NAME'...${NC}"
# Try with sudo first as it's likely root-owned
if sudo virsh net-info "$NET_NAME" >/dev/null 2>&1; then
    sudo virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
    sudo virsh net-undefine "$NET_NAME"
    echo "Network removed."
else
    echo "Network '$NET_NAME' not found."
fi

# 2.1 Clean up host networking (for 'none' driver)
HOST_IFACE="virbr-pxe"
MINIKUBE_IP="192.168.100.2"
if ip addr show "$HOST_IFACE" 2>/dev/null | grep -q "inet $MINIKUBE_IP/"; then
    echo -e "${GREEN}--> Removing IP $MINIKUBE_IP from $HOST_IFACE...${NC}"
    sudo ip addr del "$MINIKUBE_IP/24" dev "$HOST_IFACE"
fi

# 3. Delete Minikube
echo -e "${GREEN}--> Deleting Minikube cluster...${NC}"
# Check if using 'none' driver
if minikube profile list -o json | grep -q '"Driver": "none"'; then
    echo "Detected 'none' driver. Running delete with sudo to clean up root-owned artifacts..."
    sudo -E minikube delete
else
    minikube delete
fi

# 4. Remove Docker Images (Optional)
if [ "$REMOVE_IMAGES" = true ]; then
    echo -e "${GREEN}--> Removing Docker images...${NC}"
    # List of images to remove
    IMAGES="localhost/http-server:latest localhost/smd:local-smd localhost/bss:local-bss localhost/coresmd:local-coresmd"
    for img in $IMAGES; do
        if docker image inspect "$img" >/dev/null 2>&1; then
            docker rmi "$img" || echo "Failed to remove $img (might be in use or dependent)"
        fi
    done
else
    echo -e "${GREEN}--> Skipping Docker image removal.${NC}"
fi

# 5. Remove Artifacts
echo -e "${GREEN}--> Cleaning up build artifacts...${NC}"
rm -f ochami-helm/http-server/artifacts/vmlinuz-lts
rm -f ochami-helm/http-server/artifacts/initramfs-lts
rm -f ochami-helm/http-server/artifacts/rootfs.squashfs
rm -f /tmp/configure_net.sh 2>/dev/null || true

# 6. Clean up System Modifications (Optional/Aggressive)
if [ "$REMOVE_IMAGES" = true ]; then
    echo -e "${GREEN}--> Removing CNI plugins (/opt/cni)...${NC}"
    if [ -d "/opt/cni" ]; then
        sudo rm -rf "/opt/cni"
    fi
fi

# Revert sysctl change (if it was changed to 0)
if [ "$(sysctl -n fs.protected_regular)" = "0" ]; then
    echo -e "${GREEN}--> Reverting fs.protected_regular to 1...${NC}"
    sudo sysctl -w fs.protected_regular=1 >/dev/null 2>&1 || true
fi

echo -e "${GREEN}=== Teardown Complete ===${NC}"