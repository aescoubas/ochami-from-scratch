#!/bin/bash
set -e

# scripts/teardown/quadlets.sh — Teardown OpenCHAMI Quadlets deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Teardown an OpenCHAMI Quadlets deployment."
    echo ""
    echo "This script removes:"
    echo "  - Test VMs (virtual-compute-node or specified name)"
    echo "  - Podman Quadlet services and files"
    echo "  - The pxe-net libvirt network"
    echo "  - Host networking configuration"
    echo "  - Build artifacts (kernels, initramfs, rootfs)"
    echo ""
    add_common_teardown_args_help
}

# --- Parse Arguments ---
rc=0
parse_common_teardown_args "$@" || rc=$?
if [ $rc -eq 2 ]; then
    show_help
    exit 0
elif [ $rc -ne 0 ]; then
    exit $rc
fi

# --- Confirmation ---
confirm_teardown "Quadlets"
echo "  - Quadlet services"
echo "  - Build artifacts (kernels, initramfs, rootfs)"
if [ "$REMOVE_IMAGES" = true ]; then
    echo "  - Podman images (ochami related) [ENABLED]"
else
    echo "  - Podman images (ochami related) [SKIPPED - use --remove-images to delete]"
fi
echo ""
prompt_confirmation

# 1. Destroy VMs
destroy_vms "$VM_NAME"

# 2. Stop and remove Quadlet
step "Removing Quadlet deployment..."
if systemctl list-units --full -all | grep -q "ochami.service"; then
    echo "Stopping ochami.service..."
    sudo systemctl stop ochami.service
fi

if [ -f "/etc/containers/systemd/ochami.kube" ] || [ -f "/etc/containers/systemd/ochami.yaml" ]; then
    echo "Removing Podman Quadlet files..."
    sudo rm -f /etc/containers/systemd/ochami.kube /etc/containers/systemd/ochami.yaml
    sudo systemctl daemon-reload
    echo "Podman Quadlet removed."
fi

# 3. Destroy Network
destroy_pxe_network

# 4. Clean up host networking
cleanup_host_networking

# 5. Remove Podman Images (Optional)
if [ "$REMOVE_IMAGES" = true ]; then
    IMAGES=(
        "localhost/http-server:latest"
        "localhost/tftp:latest"
        "localhost/smd:local-smd"
        "localhost/bss:local-bss"
        "ghcr.io/openchami/cloud-init:v1.2.3"
        "localhost/stork-agent:latest"
        "signalorange/stork:ubuntu24.04-1.19.0"
    )
    if command_exists podman; then
        remove_images "sudo podman" "${IMAGES[@]}"
    fi
else
    step "Skipping image removal."
fi

# 6. Remove Artifacts
cleanup_build_artifacts

info "=== Teardown Complete ==="
