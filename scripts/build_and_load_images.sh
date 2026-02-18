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
cat > "$BUILD_DIR/Dockerfile" <<EOF_DOCKER
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
EOF_DOCKER

# Build the image
$CONTAINER_TOOL build -t custom-image-builder-sles "$BUILD_DIR"

# Create a container from the image
CONTAINER_ID=$($CONTAINER_TOOL create custom-image-builder-sles)

# Extract kernel and new initramfs
$CONTAINER_TOOL cp "$CONTAINER_ID:/boot/initrd.img" ./initramfs-lts

# Copy likely kernel locations and search vmlinuz across all of them.
sudo rm -rf ./boot_tmp ./modules_tmp ./usr_modules_tmp
VMLINUZ_SEARCH_DIRS=()

mkdir -p ./boot_tmp
$CONTAINER_TOOL cp "$CONTAINER_ID:/boot/." ./boot_tmp/
relax_permissions ./boot_tmp
VMLINUZ_SEARCH_DIRS+=("./boot_tmp")

if $CONTAINER_TOOL cp "$CONTAINER_ID:/lib/modules" ./modules_tmp; then
    relax_permissions ./modules_tmp
    VMLINUZ_SEARCH_DIRS+=("./modules_tmp")
fi

if $CONTAINER_TOOL cp "$CONTAINER_ID:/usr/lib/modules" ./usr_modules_tmp 2>/dev/null; then
    relax_permissions ./usr_modules_tmp
    VMLINUZ_SEARCH_DIRS+=("./usr_modules_tmp")
fi

VMLINUZ=""
KERNEL_PATTERNS=("vmlinuz*" "Image*" "bzImage*" "linux*" "kernel*")
for search_dir in "${VMLINUZ_SEARCH_DIRS[@]}"; do
    for pattern in "${KERNEL_PATTERNS[@]}"; do
        candidate=$(find -L "$search_dir" -type f -name "$pattern" | head -n 1 || true)
        if [ -n "$candidate" ]; then
            VMLINUZ="$candidate"
            break
        fi
    done

    if [ -n "$VMLINUZ" ]; then
        break
    fi
done

if [ -z "$VMLINUZ" ]; then
    # Last-resort fallback for layouts exposing only uncompressed vmlinux.
    for search_dir in "${VMLINUZ_SEARCH_DIRS[@]}"; do
        candidate=$(find -L "$search_dir" -type f -name "vmlinux*" | head -n 1 || true)
        if [ -n "$candidate" ]; then
            echo "Warning: using fallback kernel artifact '$candidate' (vmlinux*)." >&2
            VMLINUZ="$candidate"
            break
        fi
    done
fi

if [ -z "$VMLINUZ" ]; then
    echo "Error: vmlinuz not found in copied container paths."
    echo "Searched directories: ${VMLINUZ_SEARCH_DIRS[*]}"
    for search_dir in "${VMLINUZ_SEARCH_DIRS[@]}"; do
        if [ -d "$search_dir" ]; then
            ls -R "$search_dir"
        fi
    done
    exit 1
fi

cp "$VMLINUZ" ./vmlinuz-lts
rm -rf ./boot_tmp ./modules_tmp ./usr_modules_tmp

# Create a squashfs rootfs
$CONTAINER_TOOL export "$CONTAINER_ID" > "$BUILD_DIR/rootfs.tar"
mkdir -p "$BUILD_DIR/full_root"
sudo tar -xf "$BUILD_DIR/rootfs.tar" -C "$BUILD_DIR/full_root"

# Create squashfs
if command_exists mksquashfs; then
    sudo mksquashfs "$BUILD_DIR/full_root" ./rootfs.squashfs -noappend -wildcards -e "proc/*" -e "sys/*" -e "dev/*" -e "tmp/*" -e "boot/*" -e "var/cache/zypp/*"
else
    echo "mksquashfs not found on host; using containerized mksquashfs."
    $CONTAINER_TOOL run --rm \
        -v "$BUILD_DIR/full_root:/input:ro" \
        -v "$(pwd):/output" \
        custom-image-builder-sles \
        mksquashfs /input /output/rootfs.squashfs -noappend -wildcards -e "proc/*" -e "sys/*" -e "dev/*" -e "tmp/*" -e "boot/*" -e "var/cache/zypp/*"
fi
relax_permissions ./rootfs.squashfs

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
