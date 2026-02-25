#!/bin/bash
set -e

# scripts/deploy/docker-compose.sh — Deploy OpenCHAMI using Docker Compose

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lib/pipeline.sh"
source "$SCRIPT_DIR/lib/runtime_config.sh"

COMPOSE_DIR="$PROJECT_ROOT/ochami-docker-compose"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy OpenCHAMI using Docker Compose with locally-built images."
    echo ""
    add_common_deploy_args_help
}

common_deploy_bootstrap "OpenCHAMI Docker Compose Deployment" "$@"

# 0. Install Prerequisites
common_install_prerequisites

# 1. Check Prerequisites
step "Checking prerequisites for docker-compose..."
require_command docker
if ! docker compose version >/dev/null 2>&1; then
    if ! command_exists docker-compose; then
        error "docker compose (plugin or standalone) is required but not installed. Aborting."
        exit 1
    fi
fi
if ! $IS_MACOS && [ "$MODE" == "libvirt" ]; then
    require_command virt-install "virt-install is required for libvirt mode but not installed. Aborting."
fi

# Determine compose command
COMPOSE_CMD="docker compose"
if ! docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
fi

# Build compose file list (macOS uses bridge networking override)
COMPOSE_FILES=(-f "$COMPOSE_DIR/docker-compose.yml")
if $IS_MACOS; then
    COMPOSE_FILES+=(-f "$COMPOSE_DIR/docker-compose.macos.yml")
fi

# 2. Build and Load Images
step "Building and loading images..."
build_images_if_needed "docker" "docker-compose" "$FORCE_REBUILD"

# 3. Configure Network
step "Configuring PXE network (Mode: $MODE)..."

if $IS_MACOS; then
    echo "macOS: Skipping host network configuration (Docker Desktop manages networking)."
    echo "macOS: Services will communicate via Docker bridge network."
else
    if [ "$MODE" == "hardware" ]; then
        PXE_INTERFACE=$(configure_hardware_network "$PXE_INTERFACE" "$PHY_IFACE")
        PHY_IFACE=""
    fi

    if [ "$MODE" == "libvirt" ]; then
        configure_libvirt_network "$PXE_INTERFACE"
    else
        echo "Hardware mode selected. Skipping libvirt network creation."
    fi

    "$PROJECT_ROOT/scripts/setup_minikube_net.sh" "$PXE_INTERFACE" "$PXE_IP" "$PXE_CIDR" "$PHY_IFACE"

    # 3b. Check for DHCP port conflicts (e.g. dnsmasq from libvirt)
    check_dhcp_port_conflict "$PXE_INTERFACE" "$DHCP_CONFLICT_POLICY"
fi

# 4. Generate configuration files
step "Generating configuration files..."
HOST_IP="$PXE_IP"
echo "Using Host IP for PXE boot: $HOST_IP"

# On macOS with bridge networking, Kea must listen on all interfaces inside its container
if $IS_MACOS; then
    PXE_INTERFACE="*"
fi

export_runtime_template_vars

# Generate .env file
generate_docker_compose_env_file "$COMPOSE_DIR/.env"

# Generate config files from templates
mkdir -p "$COMPOSE_DIR/configs"

if [ -f "$COMPOSE_DIR/configs/kea-dhcp4.conf.template" ]; then
    # Use explicit variable list to protect iPXE variable ${mac} from substitution.
    render_template_file "$COMPOSE_DIR/configs/kea-dhcp4.conf.template" \
        "$COMPOSE_DIR/configs/kea-dhcp4.conf" "$(runtime_kea_template_vars)"
fi

if [ -f "$SHARED_NGINX_TEMPLATE" ]; then
    render_template_file "$SHARED_NGINX_TEMPLATE" "$COMPOSE_DIR/configs/nginx-default.conf" "$(runtime_nginx_template_vars)"
fi

if [ -f "$COMPOSE_DIR/configs/boot.ipxe.template" ]; then
    render_template_file "$COMPOSE_DIR/configs/boot.ipxe.template" "$COMPOSE_DIR/configs/boot.ipxe" "$(runtime_boot_template_vars)"
fi

if [ -f "$COMPOSE_DIR/configs/stork-server.env.template" ]; then
    render_template_file "$COMPOSE_DIR/configs/stork-server.env.template" "$COMPOSE_DIR/configs/stork-server.env"
fi

# 5. Configure firewall
configure_firewall "$PXE_INTERFACE"

# 6. Start services
step "Starting Docker Compose services..."

COMPOSE_PROFILES=()
if [ "$NUM_VMS" -gt 0 ]; then
    COMPOSE_PROFILES=(--profile emulator)
fi

$COMPOSE_CMD -p ochami "${COMPOSE_FILES[@]}" --env-file "$COMPOSE_DIR/.env" "${COMPOSE_PROFILES[@]}" up -d --wait

# 7. Wait for services
step "Waiting for services to be ready..."
wait_for_url "http://localhost:${SMD_PORT}/hsm/v2/service/ready" "SMD"
wait_for_url "http://localhost:${BSS_PORT}/boot/v1/bootparameters" "BSS"
wait_for_url "http://localhost:${CLOUD_INIT_PORT}/cloud-init/version" "cloud-init"
wait_for_url "http://localhost:${PCS_PORT}/liveness" "PCS (Power Control)"
wait_for_url "http://localhost:${STORK_PORT}/api/version" "Stork (Kea DHCP Monitor)"

# 8. Configure BSS
step "Configuring BSS Default Boot Parameters..."
register_bss_defaults "localhost" "$HOST_IP" "ds=nocloud-net;s=http://${HOST_IP}:${HTTP_PORT}/cloud-init/"

# 8b/9. Discover/register hardware nodes and create VMs
VM_CREATION_SUPPORTED=true
if $IS_MACOS; then
    VM_CREATION_SUPPORTED=false
fi
common_run_post_deploy_flow "docker-compose" "$HOST_IP" "$VM_CREATION_SUPPORTED"

# 10. Final Instructions
info "=== Deployment Complete ==="
echo "  Stork DHCP Monitor: http://localhost:${STORK_PORT}/ (login: admin/admin)"
echo ""
echo "You can now verify the services are running:"
echo "  $COMPOSE_CMD ${COMPOSE_FILES[*]} ps"
echo ""
echo "View logs:"
echo "  $COMPOSE_CMD ${COMPOSE_FILES[*]} logs -f"
echo ""
common_print_vm_instructions "$VM_CREATION_SUPPORTED"
