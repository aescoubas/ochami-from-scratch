#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${RED}=== OpenCHAMI Teardown Script ===${NC}"
echo "This script will PERMANENTLY DELETE:"
echo "  - VM: virtual-compute-node"
echo "  - Network: pxe-net"
echo "  - Minikube Cluster"
echo "  - Docker Images (ochami related)"
echo "  - Build Artifacts (kernels, initramfs)"
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

# 3. Delete Minikube (Run as user)
echo -e "${GREEN}--> Deleting Minikube cluster...${NC}"
minikube delete

# 4. Remove Docker Images
echo -e "${GREEN}--> Removing Docker images...${NC}"
# List of images to remove
IMAGES="localhost/http-server:latest localhost/smd:local-smd localhost/bss:local-bss localhost/coresmd:local-coresmd"
for img in $IMAGES; do
    if docker image inspect "$img" >/dev/null 2>&1; then
        docker rmi "$img" || echo "Failed to remove $img (might be in use or dependent)"
    fi
done

# 5. Remove Artifacts
echo -e "${GREEN}--> Cleaning up build artifacts...${NC}"
rm -f ochami-helm/http-server/artifacts/vmlinuz-lts
rm -f ochami-helm/http-server/artifacts/initramfs-lts
rm -f ochami-helm/http-server/artifacts/rootfs.squashfs

echo -e "${GREEN}=== Teardown Complete ===${NC}"
