#!/bin/bash
set -e

# scripts/teardown/minikube.sh — Teardown OpenCHAMI Minikube deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Teardown an OpenCHAMI Minikube deployment."
    echo ""
    echo "This script removes:"
    echo "  - Test VMs (virtual-compute-node or specified name)"
    echo "  - The pxe-net libvirt network"
    echo "  - Host networking configuration"
    echo "  - The Minikube cluster"
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
confirm_teardown "Minikube"
echo "  - Minikube cluster"
echo "  - Build artifacts (kernels, initramfs, rootfs)"
if [ "$REMOVE_IMAGES" = true ]; then
    echo "  - Docker images (ochami related) [ENABLED]"
else
    echo "  - Docker images (ochami related) [SKIPPED - use --remove-images to delete]"
fi
echo ""
prompt_confirmation

# 1. Destroy VMs
destroy_vms "$VM_NAME"

# 2. Destroy Network
destroy_pxe_network

# 3. Clean up host networking
cleanup_host_networking

# 4. Delete Minikube
step "Deleting Minikube cluster..."
if command_exists minikube; then
    if $IS_MACOS; then
        minikube delete
    elif minikube profile list -o json 2>/dev/null | grep -q '"Driver": "none"'; then
        echo "Detected 'none' driver. Running delete with sudo to clean up root-owned artifacts..."
        sudo -E minikube delete
    else
        minikube delete
    fi
else
    echo "minikube not found, skipping cluster deletion."
fi

# 5. Remove Docker Images (Optional)
if [ "$REMOVE_IMAGES" = true ]; then
    IMAGES=(
        "localhost/http-server:latest"
        "localhost/tftp:latest"
        "localhost/smd:local-smd"
        "localhost/bss:local-bss"
        "localhost/pcs:local-pcs"
        "ghcr.io/openchami/cloud-init:v1.2.3"
        "localhost/stork-agent:latest"
        "localhost/kea-sidecar:latest"
        "signalorange/stork:ubuntu24.04-1.19.0"
    )
    if command_exists docker; then
        remove_images "docker" "${IMAGES[@]}"
    fi
else
    step "Skipping Docker image removal."
fi

# 6. Remove Artifacts
cleanup_build_artifacts

# 7. Clean up System Modifications
if [ "$REMOVE_IMAGES" = true ]; then
    step "Removing CNI plugins (/opt/cni)..."
    if [ -d "/opt/cni" ]; then
        sudo rm -rf "/opt/cni"
    fi
fi

# Revert sysctl change (Linux only)
if ! $IS_MACOS; then
    if [ "$(sysctl -n fs.protected_regular 2>/dev/null)" = "0" ]; then
        step "Reverting fs.protected_regular to 1..."
        sudo sysctl -w fs.protected_regular=1 >/dev/null 2>&1 || true
    fi
fi

info "=== Teardown Complete ==="
