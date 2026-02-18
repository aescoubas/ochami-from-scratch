#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

# Configuration
CONTAINER_TOOL=${CONTAINER_TOOL:-docker}
ORCHESTRATOR=${ORCHESTRATOR:-minikube}

echo "--- Building SLES 15 SP6 (openSUSE Leap 15.6) image artifacts using $CONTAINER_TOOL ---"

# Create a temporary directory
BUILD_DIR=$(mktemp -d)
trap 'sudo rm -rf -- "$BUILD_DIR"' EXIT

# Create custom Wicked XML config on host
cat > "$BUILD_DIR/eth0.xml" <<XML
<interface>
  <name>eth0</name>
  <control>
    <mode>boot</mode>
  </control>
  <ipv4>
    <enabled>true</enabled>
    <dhcp>
      <enabled>true</enabled>
      <option>
        <code value="93"/>
        <type>uint16</type>
        <value>0</value>
      </option>
    </dhcp>
  </ipv4>
</interface>
XML

# Create a Dockerfile to build the image
cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM ${BASE_IMAGE_SLES_BUILDER}
RUN zypper ref && zypper install -y kernel-default dracut squashfs iproute2 util-linux shadow device-mapper tar dhcp-client curl udev

# Configure system
RUN echo 'root:root' | chpasswd

# Copy custom Wicked XML config
RUN mkdir -p /tmp/netconfig
COPY eth0.xml /tmp/netconfig/eth0.xml

# Generate Dracut initramfs with network and live boot support
# We include the custom XML config in the correct path for wicked
# Wicked usually looks in /etc/wicked/ifconfig/
RUN KVER=\$(ls /lib/modules | head -n 1) && \
    dracut -v --add "network dmsquash-live livenet" --include /tmp/netconfig/eth0.xml /etc/wicked/ifconfig/eth0.xml --no-hostonly --kver \$KVER /boot/initrd.img
EOF

# Build the image
$CONTAINER_TOOL build -t custom-image-builder-sles "$BUILD_DIR"

# Create a container from the image
CONTAINER_ID=$($CONTAINER_TOOL create custom-image-builder-sles)

# Extract kernel and new initramfs
$CONTAINER_TOOL cp "$CONTAINER_ID:/boot/initrd.img" ./initramfs-lts
# Copy the entire /boot to find vmlinuz
sudo rm -rf ./boot_tmp
mkdir -p ./boot_tmp
$CONTAINER_TOOL cp "$CONTAINER_ID:/boot/." ./boot_tmp/
sudo chown -R "$(get_invoking_chown_owner)" ./boot_tmp

# Find the vmlinuz file
VMLINUZ=$(find ./boot_tmp -name "vmlinuz*" -type f | head -n 1)

if [ -z "$VMLINUZ" ]; then
     echo "Checking /lib/modules for vmlinuz..."
     $CONTAINER_TOOL cp "$CONTAINER_ID:/lib/modules" ./modules_tmp
     VMLINUZ_MOD=$(find ./modules_tmp -name "vmlinuz" -type f | head -n 1)
     if [ -n "$VMLINUZ_MOD" ]; then
         echo "Found vmlinuz in modules"
         cp "$VMLINUZ_MOD" ./vmlinuz-lts
         rm -rf ./modules_tmp
     else
        echo "Error: vmlinuz not found"
        ls -R ./boot_tmp
        exit 1
     fi
else
    cp "$VMLINUZ" ./vmlinuz-lts
fi

rm -rf ./boot_tmp

# Create a squashfs rootfs
$CONTAINER_TOOL export "$CONTAINER_ID" > "$BUILD_DIR/rootfs.tar"
mkdir -p "$BUILD_DIR/full_root"
sudo tar -xf "$BUILD_DIR/rootfs.tar" -C "$BUILD_DIR/full_root"

# Create squashfs
sudo mksquashfs "$BUILD_DIR/full_root" ./rootfs.squashfs -noappend -wildcards -e "proc/*" -e "sys/*" -e "dev/*" -e "tmp/*" -e "boot/*" -e "var/cache/zypp/*"
sudo chown "$(get_invoking_chown_owner)" ./rootfs.squashfs

# Clean up
$CONTAINER_TOOL rm "$CONTAINER_ID"
$CONTAINER_TOOL rmi -f custom-image-builder-sles || true

echo "--- Staging artifacts ---"
ARTIFACTS_DIR="ochami-helm/http-server/artifacts"
mkdir -p "$ARTIFACTS_DIR"
mv vmlinuz-lts initramfs-lts rootfs.squashfs "$ARTIFACTS_DIR/"
echo "Artifacts staged in $ARTIFACTS_DIR"

echo "--- Building and loading http-server image into Minikube ---"
DOCKER_CONTEXT="ochami-helm/http-server/"
$CONTAINER_TOOL build --build-arg BASE_IMAGE="$BASE_IMAGE_HTTP_SERVER" -t localhost/http-server:latest "$DOCKER_CONTEXT"
if [ "$ORCHESTRATOR" == "minikube" ]; then
    minikube image load localhost/http-server:latest
fi

# Note: TFTP server is built into coresmd, no separate container needed
# coresmd includes iPXE binaries (undionly.kpxe, ipxe.efi) for BIOS and UEFI boot

echo "--- Building redfish-emulator ---"
$CONTAINER_TOOL build --build-arg BASE_IMAGE="$BASE_IMAGE_REDFISH_EMULATOR" -t localhost/redfish-emulator:latest ochami-helm/redfish-emulator/
if [ "$ORCHESTRATOR" == "minikube" ]; then
    minikube image load localhost/redfish-emulator:latest
fi

echo "--- Done ---"
