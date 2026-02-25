#!/bin/bash
set -e

# scripts/teardown/quadlets.sh — Teardown OpenCHAMI Quadlets deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

require_linux "Quadlets teardown"

QUADLETS_INSTALL_DIR="/etc/containers/systemd"
OPENCHAMI_CONFIG_DIR="/etc/openchami"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Teardown an OpenCHAMI Quadlets deployment."
    echo ""
    echo "This script removes:"
    echo "  - Test VMs (virtual-compute-node or specified name)"
    echo "  - Podman Quadlet services (openchami.target + individual .container units)"
    echo "  - OpenCHAMI configuration files (/etc/openchami/)"
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
echo "  - Quadlet services (openchami.target + individual containers)"
echo "  - OpenCHAMI config directory ($OPENCHAMI_CONFIG_DIR)"
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

# 2. Stop and remove Quadlet services
step "Removing Quadlet deployment..."

# Stop openchami.target (stops all dependent services)
if systemctl list-units --full -all | grep -q "openchami.target"; then
    echo "Stopping openchami.target..."
    sudo systemctl stop openchami.target || true
fi

# Also stop the legacy ochami.service if it exists (backward compat)
if systemctl list-units --full -all | grep -q "ochami.service"; then
    echo "Stopping legacy ochami.service..."
    sudo systemctl stop ochami.service || true
fi

# Stop any individual quadlet-generated services that may still be running
echo "Stopping any remaining OpenCHAMI container services..."
for unit in $(systemctl list-units --full -all --no-legend 'postgres.service' 'smd*.service' 'bss*.service' 'cloud-init*.service' 'pcs*.service' 'kea*.service' 'stork*.service' 'http-server.service' 'tftp.service' 'redfish-emulator*.service' 2>/dev/null | awk '{print $1}'); do
    sudo systemctl stop "$unit" 2>/dev/null || true
done

# Remove quadlet container files
echo "Removing Quadlet files from $QUADLETS_INSTALL_DIR..."
sudo rm -f "$QUADLETS_INSTALL_DIR"/*.container

# Remove target from systemd directory (targets are plain systemd units, not quadlets)
echo "Removing openchami.target from /etc/systemd/system/..."
sudo rm -f /etc/systemd/system/openchami.target

# Also clean up legacy monolithic files
sudo rm -f "$QUADLETS_INSTALL_DIR"/ochami.kube "$QUADLETS_INSTALL_DIR"/ochami.yaml

sudo systemctl daemon-reload
echo "Quadlet services removed."

# 3. Remove OpenCHAMI config directory
if [ -d "$OPENCHAMI_CONFIG_DIR" ]; then
    step "Removing OpenCHAMI config directory..."
    sudo rm -rf "$OPENCHAMI_CONFIG_DIR"
    echo "Config directory removed."
fi

# 4. Remove podman volumes
step "Removing Podman volumes..."
for vol in postgres-data kea-sockets; do
    if sudo podman volume exists "systemd-$vol" 2>/dev/null; then
        sudo podman volume rm "systemd-$vol" 2>/dev/null || echo "Failed to remove volume systemd-$vol (might be in use)"
    fi
done

# 5. Destroy Network
destroy_pxe_network

# 6. Clean up host networking
cleanup_host_networking

# 7. Remove Podman Images (Optional)
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
        "localhost/redfish-emulator:latest"
        "signalorange/stork:ubuntu24.04-1.19.0"
        "postgres:11.5-alpine"
        "jonasal/kea-admin:3.1.4"
        "jonasal/kea-dhcp4:3.1.4"
        "jonasal/kea-ctrl-agent:3.1.4"
    )
    if command_exists podman; then
        remove_images "sudo podman" "${IMAGES[@]}"
    fi
else
    step "Skipping image removal."
fi

# 8. Remove Artifacts
cleanup_build_artifacts

# Restore sysctl only when managed by OpenCHAMI prereqs
restore_fs_protected_regular_if_managed

info "=== Teardown Complete ==="
