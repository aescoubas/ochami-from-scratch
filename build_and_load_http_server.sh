#!/bin/bash

set -e

echo "--- Building custom image artifacts ---"

# Create a temporary directory
BUILD_DIR=$(mktemp -d)
trap 'rm -rf -- "$BUILD_DIR"' EXIT

# Create a Dockerfile to build the image
cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM alpine:latest
RUN apk add --no-cache linux-lts squashfs-tools
RUN mkdir -p /rootfs/bin && \
    echo '#!/bin/sh' > /rootfs/bin/hello && \
    echo 'echo "Hello from a custom rootfs!"' >> /rootfs/bin/hello && \
    chmod +x /rootfs/bin/hello
EOF

# Build the image
docker build -t custom-image-builder "$BUILD_DIR"

# Create a container from the image
CONTAINER_ID=$(docker create custom-image-builder)

# Extract kernel and initramfs
docker cp "$CONTAINER_ID:/boot/vmlinuz-lts" ./vmlinuz-lts
docker cp "$CONTAINER_ID:/boot/initramfs-lts" ./initramfs-lts

# Create a squashfs rootfs
docker cp "$CONTAINER_ID:/rootfs" "$BUILD_DIR/rootfs"
mksquashfs "$BUILD_DIR/rootfs" ./rootfs.squashfs -noappend

# Clean up
docker rm "$CONTAINER_ID"
docker rmi custom-image-builder

echo "--- Staging artifacts ---"
ARTIFACTS_DIR="ochami-helm/http-server/artifacts"
mkdir -p "$ARTIFACTS_DIR"
mv vmlinuz-lts initramfs-lts rootfs.squashfs "$ARTIFACTS_DIR/"
echo "Artifacts staged in $ARTIFACTS_DIR"

echo "--- Building and loading http-server image into Minikube ---"
DOCKER_CONTEXT="ochami-helm/http-server/"
docker build -t localhost/http-server:v2 "$DOCKER_CONTEXT"
minikube image load localhost/http-server:v2

echo "--- Done ---"
