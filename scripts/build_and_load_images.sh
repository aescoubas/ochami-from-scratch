#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

# Configuration
CONTAINER_TOOL=${CONTAINER_TOOL:-docker}
CONTAINER_RUNTIME="${CONTAINER_TOOL##* }"
ORCHESTRATOR=${ORCHESTRATOR:-minikube}

run_container_tool() {
    # CONTAINER_TOOL may be a prefixed command such as "sudo podman".
    # shellcheck disable=SC2086
    $CONTAINER_TOOL "$@"
}

prepare_rootfs_variant() {
    local source_root="$1"
    local variant_name="$2"
    local prompt_label="$3"
    local output_squashfs="$4"
    local variant_root="$BUILD_DIR/full_root_${variant_name}"

    sudo rm -rf "$variant_root"
    sudo mkdir -p "$variant_root"
    sudo cp -a "$source_root/." "$variant_root/"

    sudo mkdir -p "$variant_root/etc/profile.d"
    cat <<EOF_PROMPT | sudo tee "$variant_root/etc/profile.d/99-openchami-ps1.sh" >/dev/null
#!/bin/sh
if [ "\$(id -u)" -eq 0 ]; then
    xname="\$(hostname -s 2>/dev/null || hostname)"
    export PS1="<\${xname}> ${prompt_label} : "
fi
EOF_PROMPT
    sudo chmod 0644 "$variant_root/etc/profile.d/99-openchami-ps1.sh"

    sudo mksquashfs "$variant_root" "$output_squashfs" -noappend -wildcards -e "proc/*" -e "sys/*" -e "dev/*" -e "tmp/*" -e "boot/*" -e "var/cache/zypp/*"
    relax_permissions "$output_squashfs"
}

build_local_image() {
    local image="$1"
    local context="$2"
    shift 2
    local build_args=("$@")

    if [ "$CONTAINER_RUNTIME" != "docker" ]; then
        run_container_tool build "${build_args[@]}" -t "$image" "$context"
        return 0
    fi

    docker build "${build_args[@]}" -t "$image" "$context"
    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi

    echo "docker build did not load '$image' locally; retrying with buildx --load."
    docker buildx build --load "${build_args[@]}" -t "$image" "$context"
}

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
run_container_tool build -t custom-image-builder-sles "$BUILD_DIR"

# Create a container from the image
CONTAINER_ID=$(run_container_tool create custom-image-builder-sles)

# Extract kernel and new initramfs
run_container_tool cp "$CONTAINER_ID:/boot/initrd.img" ./initramfs-lts

# Copy likely kernel locations and search vmlinuz across all of them.
sudo rm -rf ./boot_tmp ./modules_tmp ./usr_modules_tmp
VMLINUZ_SEARCH_DIRS=()

mkdir -p ./boot_tmp
run_container_tool cp "$CONTAINER_ID:/boot/." ./boot_tmp/
relax_permissions ./boot_tmp
VMLINUZ_SEARCH_DIRS+=("./boot_tmp")

if run_container_tool cp "$CONTAINER_ID:/lib/modules" ./modules_tmp; then
    relax_permissions ./modules_tmp
    VMLINUZ_SEARCH_DIRS+=("./modules_tmp")
fi

if run_container_tool cp "$CONTAINER_ID:/usr/lib/modules" ./usr_modules_tmp 2>/dev/null; then
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
run_container_tool export "$CONTAINER_ID" > "$BUILD_DIR/rootfs.tar"
mkdir -p "$BUILD_DIR/full_root"
sudo tar -xf "$BUILD_DIR/rootfs.tar" -C "$BUILD_DIR/full_root"

# Create squashfs variants
require_command mksquashfs "mksquashfs is required. On macOS run ./scripts/install_prerequisites_macos.sh (installs 'squashfs' via brew)."
prepare_rootfs_variant "$BUILD_DIR/full_root" "opensuse" "opensuse" "$BUILD_DIR/rootfs-opensuse.squashfs"
prepare_rootfs_variant "$BUILD_DIR/full_root" "ubuntu" "ubuntu" "$BUILD_DIR/rootfs-ubuntu.squashfs"

# Clean up
run_container_tool rm "$CONTAINER_ID"
run_container_tool rmi -f custom-image-builder-sles || true

echo "--- Staging artifacts ---"
ARTIFACTS_DIR="$PROJECT_ROOT/ochami-helm/http-server/artifacts"
OPENSUSE_ARTIFACTS_DIR="$ARTIFACTS_DIR/opensuse"
UBUNTU_ARTIFACTS_DIR="$ARTIFACTS_DIR/ubuntu"
rm -f "$ARTIFACTS_DIR/vmlinuz-lts" "$ARTIFACTS_DIR/initramfs-lts" "$ARTIFACTS_DIR/rootfs.squashfs"
rm -rf "$OPENSUSE_ARTIFACTS_DIR" "$UBUNTU_ARTIFACTS_DIR"
mkdir -p "$OPENSUSE_ARTIFACTS_DIR" "$UBUNTU_ARTIFACTS_DIR"
cp vmlinuz-lts initramfs-lts "$OPENSUSE_ARTIFACTS_DIR/"
cp vmlinuz-lts initramfs-lts "$UBUNTU_ARTIFACTS_DIR/"
mv "$BUILD_DIR/rootfs-opensuse.squashfs" "$OPENSUSE_ARTIFACTS_DIR/rootfs.squashfs"
mv "$BUILD_DIR/rootfs-ubuntu.squashfs" "$UBUNTU_ARTIFACTS_DIR/rootfs.squashfs"
echo "Artifacts staged in $OPENSUSE_ARTIFACTS_DIR and $UBUNTU_ARTIFACTS_DIR"

echo "--- Building and loading http-server image into Minikube ---"
DOCKER_CONTEXT="$PROJECT_ROOT/ochami-helm/http-server/"
build_local_image "localhost/http-server:latest" "$DOCKER_CONTEXT" --build-arg BASE_IMAGE="$BASE_IMAGE_HTTP_SERVER"
if [ "$ORCHESTRATOR" == "minikube" ]; then
    if [ "$CONTAINER_RUNTIME" == "docker" ]; then
        docker save "localhost/http-server:latest" | minikube image load -
    else
        minikube image load localhost/http-server:latest
    fi
fi

# Note: TFTP server is built into coresmd, no separate container needed
# coresmd includes iPXE binaries (undionly.kpxe, ipxe.efi) for BIOS and UEFI boot

echo "--- Building redfish-emulator ---"
build_local_image "localhost/redfish-emulator:latest" "$PROJECT_ROOT/ochami-helm/redfish-emulator/" --build-arg BASE_IMAGE="$BASE_IMAGE_REDFISH_EMULATOR"
if [ "$ORCHESTRATOR" == "minikube" ]; then
    if [ "$CONTAINER_RUNTIME" == "docker" ]; then
        docker save "localhost/redfish-emulator:latest" | minikube image load -
    else
        minikube image load localhost/redfish-emulator:latest
    fi
fi

echo "--- Done ---"
