#!/bin/bash
set -e

# scripts/teardown/docker-compose.sh — Teardown OpenCHAMI Docker Compose deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

COMPOSE_DIR="$PROJECT_ROOT/ochami-docker-compose"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Teardown an OpenCHAMI Docker Compose deployment."
    echo ""
    echo "This script removes:"
    echo "  - Test VMs (virtual-compute-node or specified name)"
    echo "  - Docker Compose services and volumes"
    echo "  - Generated config files"
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

# Determine compose command
COMPOSE_CMD="docker compose"
if command_exists docker && ! docker compose version >/dev/null 2>&1; then
    if command_exists docker-compose; then
        COMPOSE_CMD="docker-compose"
    fi
fi

# --- Confirmation ---
confirm_teardown "Docker Compose"
echo "  - Docker Compose services and volumes"
echo "  - Generated config files"
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

# 2. Stop and remove Docker Compose services
step "Stopping Docker Compose services..."
if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    $COMPOSE_CMD -p ochami -f "$COMPOSE_DIR/docker-compose.yml" down -v --remove-orphans 2>/dev/null || echo "Docker Compose services already stopped or not found."
fi

# 3. Destroy Network
destroy_pxe_network

# 4. Clean up host networking
cleanup_host_networking

# 5. Remove generated config files
step "Removing generated config files..."
rm -f "$COMPOSE_DIR/.env"
rm -f "$COMPOSE_DIR/configs/kea-dhcp4.conf"
rm -f "$COMPOSE_DIR/configs/nginx-default.conf"
rm -f "$COMPOSE_DIR/configs/boot.ipxe"
rm -f "$COMPOSE_DIR/configs/stork-server.env"

# 6. Remove Docker Images (Optional)
if [ "$REMOVE_IMAGES" = true ]; then
    IMAGES=(
        "localhost/http-server:latest"
        "localhost/tftp:latest"
        "localhost/smd:local-smd"
        "localhost/bss:local-bss"
        "localhost/redfish-emulator:latest"
        "localhost/pcs:local-pcs"
        "localhost/stork-agent:latest"
        "signalorange/stork:ubuntu24.04-1.19.0"
    )
    if command_exists docker; then
        remove_images "docker" "${IMAGES[@]}"
    fi
else
    step "Skipping Docker image removal."
fi

# 7. Remove Artifacts
cleanup_build_artifacts

info "=== Teardown Complete ==="
