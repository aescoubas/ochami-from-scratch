#!/bin/bash
set -e

# scripts/deploy/quadlets.sh — Deploy OpenCHAMI using individual Podman Quadlet containers

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lib/pipeline.sh"
source "$SCRIPT_DIR/lib/runtime_config.sh"

require_linux "Quadlets deployment"

QUADLETS_DIR="$PROJECT_ROOT/ochami-quadlets"
QUADLETS_INSTALL_DIR="/etc/containers/systemd"
OPENCHAMI_CONFIG_DIR="/etc/openchami"
OPENCHAMI_CONFIGS_DIR="/etc/openchami/configs"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy OpenCHAMI using individual Podman Quadlet containers under openchami.target."
    echo ""
    echo "Each service runs as an independent systemd unit with proper dependency ordering."
    echo "Services can be individually started/stopped/restarted."
    echo ""
    add_common_deploy_args_help
}

common_deploy_bootstrap "OpenCHAMI Quadlets Deployment" "$@"

# 0. Install Prerequisites
common_install_prerequisites

# 1. Check Prerequisites
step "Checking prerequisites for quadlets..."
require_command podman
require_command envsubst "envsubst (gettext) is required but not installed. Aborting."
if [ "$MODE" == "libvirt" ]; then
    require_command virt-install "virt-install is required for libvirt mode but not installed. Aborting."
fi

# 2. Build and Load Images
step "Building and loading images..."
build_images_if_needed "sudo podman" "quadlets" "$FORCE_REBUILD"

# 3. Configure Network
step "Configuring PXE network (Mode: $MODE)..."

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

# 4. Deploy
step "Deploying OpenCHAMI (Quadlets)..."
HOST_IP="$PXE_IP"
echo "Using Host IP for PXE boot: $HOST_IP"

# Configure firewall
configure_firewall "$PXE_INTERFACE"

# 4a. Create config directory
step "Creating OpenCHAMI config directories..."
sudo mkdir -p "$OPENCHAMI_CONFIGS_DIR"

# 4b. Generate environment file
step "Generating environment file..."
generate_quadlets_env_file "$OPENCHAMI_CONFIG_DIR/openchami.env"

# 4c. Process config templates with envsubst
step "Processing config templates..."

export_runtime_template_vars

# Template variables to substitute (exclude nginx $host, $remote_addr, etc.)
ENVSUBST_VARS="$(runtime_template_vars)"
render_templates_in_dir "$QUADLETS_DIR/configs" "$OPENCHAMI_CONFIGS_DIR" "$ENVSUBST_VARS" "sudo" "nginx-default.conf"

echo "  Processing nginx-default.conf from shared template..."
render_template_file "$SHARED_NGINX_TEMPLATE" "$OPENCHAMI_CONFIGS_DIR/nginx-default.conf" "$ENVSUBST_VARS" "sudo" "false"

# Copy static config files
copy_static_config_files "$QUADLETS_DIR/configs" "$OPENCHAMI_CONFIGS_DIR" "sudo"

# Ensure postgres init script is executable
sudo chmod +x "$OPENCHAMI_CONFIGS_DIR/postgres-init-db.sh"

# 4d. Install quadlet files
step "Installing Quadlet files to $QUADLETS_INSTALL_DIR..."
sudo mkdir -p "$QUADLETS_INSTALL_DIR"

# Process .container files through envsubst (for Exec lines that need substituted values)
# then install to quadlet directory
for unit_file in "$QUADLETS_DIR/containers/"*.container; do
    [ -f "$unit_file" ] || continue
    base=$(basename "$unit_file")
    echo "  Installing $base..."
    envsubst "$ENVSUBST_VARS" < "$unit_file" | sudo tee "$QUADLETS_INSTALL_DIR/$base" > /dev/null
done

# Install .target files to systemd directory (targets are plain systemd units, not quadlets)
for unit_file in "$QUADLETS_DIR/containers/"*.target; do
    [ -f "$unit_file" ] || continue
    base=$(basename "$unit_file")
    echo "  Installing $base to /etc/systemd/system/..."
    sudo cp "$unit_file" "/etc/systemd/system/$base"
done

# 4e. Generate redfish emulator containers (if VMs requested)
if [ "$NUM_VMS" -gt 0 ]; then
    step "Generating $NUM_VMS redfish emulator quadlet files..."
    for i in $(seq 0 $((NUM_VMS - 1))); do
        EMULATOR_FILE="$QUADLETS_INSTALL_DIR/redfish-emulator-${i}.container"
        echo "  Generating redfish-emulator-${i}.container..."
        sudo tee "$EMULATOR_FILE" > /dev/null <<EMULATOR_EOF
[Unit]
Description=OpenCHAMI Redfish Emulator (VM $i)

[Container]
Image=localhost/redfish-emulator:latest
Network=host
Environment=VM_INDEX=$i
Exec=python -u -c "import os; idx=os.environ.get('VM_INDEX','0'); script=open('/emulator.py').read(); script=script.replace('INDEX = int(HOSTNAME.split(\"-\")[-1])', f'INDEX = {idx}'); exec(script)"
Volume=/var/run/libvirt/libvirt-sock:/var/run/libvirt/libvirt-sock

[Service]
Restart=on-failure
TimeoutStartSec=60

[Install]
WantedBy=openchami.target
EMULATOR_EOF
    done
fi

# 4f. Start services
step "Reloading systemd and starting OpenCHAMI services..."
sudo systemctl daemon-reload
sudo systemctl start openchami.target

# Wait for services
echo "Waiting for services to start..."
wait_for_url "http://localhost:${SMD_PORT}/hsm/v2/service/ready" "SMD"
wait_for_url "http://localhost:${BSS_PORT}/boot/v1/bootparameters" "BSS"
wait_for_url "http://localhost:${CLOUD_INIT_PORT}/cloud-init/version" "cloud-init"
wait_for_url "http://localhost:${PCS_PORT}/liveness" "PCS (Power Control)"
wait_for_url "http://localhost:${STORK_PORT}/api/version" "Stork (Kea DHCP Monitor)"

# 5. Configure BSS
step "Configuring BSS Default Boot Parameters..."
register_bss_defaults "$HOST_IP" "$HOST_IP" "ds=nocloud-net;s=http://${HOST_IP}:${HTTP_PORT}/cloud-init/"

# 5b/6. Discover/register hardware nodes and create VMs
common_run_post_deploy_flow "quadlets" "$HOST_IP" "true"

# 7. Final Instructions
info "=== Deployment Complete ==="
echo "  Stork DHCP Monitor: http://localhost:${STORK_PORT}/ (login: admin/admin)"
echo ""
echo "You can now verify the services are running:"
echo "  systemctl list-dependencies openchami.target"
echo "  sudo podman ps"
echo ""
echo "Individual service management:"
echo "  sudo systemctl status smd"
echo "  sudo systemctl restart bss"
echo "  sudo journalctl -u smd -f"
echo ""
common_print_vm_instructions "true"
