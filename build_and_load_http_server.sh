#!/bin/bash

set -e

echo "--- Building custom image artifacts ---"

# Create a temporary directory
BUILD_DIR=$(mktemp -d)
trap 'sudo rm -rf -- "$BUILD_DIR"' EXIT

# Create a Dockerfile to build the image
cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM fedora:41
RUN dnf install -y kernel dracut dracut-network dracut-live squashfs-tools iproute util-linux passwd

# Configure system
RUN echo 'root:root' | chpasswd

# Generate Dracut initramfs with network and live boot support
# We find the installed kernel version
RUN KVER=\$(ls /lib/modules | head -n 1) && \
    dracut -v --add "network dmsquash-live livenet" --no-hostonly --kver \$KVER /boot/initrd.img
EOF

# Build the image
docker build -t custom-image-builder "$BUILD_DIR"

# Create a container from the image
CONTAINER_ID=$(docker create custom-image-builder)

# Extract kernel and new initramfs
# We use find/wildcards because exact version is unknown
docker cp "$CONTAINER_ID:/boot/initrd.img" ./initramfs-lts
# Copy the entire /boot to find vmlinuz
sudo rm -rf ./boot_tmp
mkdir -p ./boot_tmp
docker cp "$CONTAINER_ID:/boot/." ./boot_tmp/
sudo chown -R $USER:$USER ./boot_tmp
# Find the vmlinuz file in boot_tmp
VMLINUZ=$(find ./boot_tmp -name "vmlinuz*" -type f | head -n 1)

if [ -z "$VMLINUZ" ]; then
    echo "Checking /lib/modules for vmlinuz..."
    docker cp "$CONTAINER_ID:/lib/modules" ./modules_tmp
    VMLINUZ_MOD=$(find ./modules_tmp -name "vmlinuz" -type f | head -n 1)
    if [ -n "$VMLINUZ_MOD" ]; then
         echo "Found vmlinuz in modules"
         cp "$VMLINUZ_MOD" ./vmlinuz-lts
         rm -rf ./modules_tmp
    else
        echo "Error: vmlinuz not found in /boot or /lib/modules"
        ls -R ./boot_tmp
        exit 1
    fi
else
    cp "$VMLINUZ" ./vmlinuz-lts
fi

rm -rf ./boot_tmp

# Create a squashfs rootfs from the entire container filesystem
# We use docker export to get a flattened filesystem with correct permissions
docker export "$CONTAINER_ID" > "$BUILD_DIR/rootfs.tar"
mkdir -p "$BUILD_DIR/full_root"
sudo tar -xf "$BUILD_DIR/rootfs.tar" -C "$BUILD_DIR/full_root"

# Create squashfs, excluding virtual filesystems and build artifacts
sudo mksquashfs "$BUILD_DIR/full_root" ./rootfs.squashfs -noappend -wildcards -e "proc/*" -e "sys/*" -e "dev/*" -e "tmp/*" -e "boot/*" -e "var/cache/dnf/*"
sudo chown $USER:$USER ./rootfs.squashfs

# Clean up
docker rm "$CONTAINER_ID"
docker rmi -f custom-image-builder || true

echo "--- Staging artifacts ---"
ARTIFACTS_DIR="ochami-helm/http-server/artifacts"
mkdir -p "$ARTIFACTS_DIR"
mv vmlinuz-lts initramfs-lts rootfs.squashfs "$ARTIFACTS_DIR/"
echo "Artifacts staged in $ARTIFACTS_DIR"

echo "--- Building and loading http-server image into Minikube ---"
DOCKER_CONTEXT="ochami-helm/http-server/"
docker build -t localhost/http-server:latest "$DOCKER_CONTEXT"

# We use minikube image load. Note: Deployment restart is handled by deploy.sh
echo "Loading image into Minikube..."
minikube image load localhost/http-server:latest --overwrite=true

echo "--- Done ---"
