#!/bin/bash
set -e

# scripts/deploy/quadlets.sh — Deploy OpenCHAMI using Podman Quadlet

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy OpenCHAMI using Podman Quadlet with host networking."
    echo ""
    add_common_deploy_args_help
}

# --- Parse Arguments ---
rc=0
parse_common_deploy_args "$@" || rc=$?
if [ $rc -eq 2 ]; then
    show_help
    exit 0
elif [ $rc -ne 0 ]; then
    exit $rc
fi

validate_common_deploy_args

info "=== OpenCHAMI Quadlets Deployment ==="

if [ "$FORCE_REBUILD" = true ]; then
    echo "Force rebuild enabled."
fi

# 0. Install Prerequisites
"$PROJECT_ROOT/scripts/install_prerequisites.sh"

# 1. Check Prerequisites
step "Checking prerequisites for quadlets..."
require_command podman
require_command helm
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
check_dhcp_port_conflict "$PXE_INTERFACE"

# 4. Deploy
step "Deploying OpenCHAMI (Quadlets)..."
HOST_IP="$PXE_IP"
echo "Using Host IP for PXE boot: $HOST_IP"

# Generate dynamic values file
VALUES_FILE=$(mktemp)
cat <<EOF > "$VALUES_FILE"
externalIp: "$HOST_IP"
pxeInterface: "$PXE_INTERFACE"
tftpServerIp: "$HOST_IP"
dhcpStart: "$DHCP_START"
dhcpEnd: "$DHCP_END"
dhcpNetmask: "$DHCP_NETMASK"
dhcpCidr: "$PXE_CIDR"
projectRoot: "$PROJECT_ROOT"
httpServer:
  hostNetwork: true
  port: 80

bss:
  ipxe:
    server: "$HOST_IP"
  advertise_address: "$HOST_IP"
  nfdUrl: "http://$HOST_IP/hmi/v1/subscribe"

kea:
  db:
    host: "ochami-postgres"
    port: 5432
    name: "kea"
    user: "kea-user"
    password: "CHANGEME"
bootScriptUrl: "http://$HOST_IP:80/boot/v1/bootscript?mac=\${net0/mac}"
EOF

if [ "$NUM_VMS" -gt 0 ]; then
cat <<EOF >> "$VALUES_FILE"
emulator:
  enabled: true
  replicas: $NUM_VMS
EOF
fi

# Configure firewall
configure_firewall "$PXE_INTERFACE"

echo "Generating Podman Quadlet configuration..."

TEMPLATE_OUT="/tmp/ochami.yaml"
# Generate YAML from Helm
helm template ochami "$PROJECT_ROOT/ochami-helm" -n ochami -f "$PROJECT_ROOT/ochami-helm/values-pxe.yaml" -f "$VALUES_FILE" > "$TEMPLATE_OUT"

# Patch YAML for Host Networking (Connection Strings)
sed -i 's/ochami-postgres/localhost/g' "$TEMPLATE_OUT"
sed -i 's/ochami-smd.ochami.svc.cluster.local/localhost/g' "$TEMPLATE_OUT"
sed -i 's/ochami-bss.ochami.svc.cluster.local/localhost/g' "$TEMPLATE_OUT"
sed -i 's/ochami-cloud-init.ochami.svc.cluster.local/localhost/g' "$TEMPLATE_OUT"
sed -i 's/ochami-pcs.ochami.svc.cluster.local/localhost/g' "$TEMPLATE_OUT"
sed -i 's/ochami-stork-server.ochami.svc.cluster.local/localhost/g' "$TEMPLATE_OUT"

# Reorder pods for Quadlet dependencies
if [ -f "$PROJECT_ROOT/scripts/quadlet_reorder.py" ]; then
    echo "Reordering Quadlet YAML..."
    /usr/bin/python3 "$PROJECT_ROOT/scripts/quadlet_reorder.py" "$TEMPLATE_OUT" "$TEMPLATE_OUT"
fi

echo "Installing Quadlet files to /etc/containers/systemd/..."
sudo cp "$TEMPLATE_OUT" /etc/containers/systemd/ochami.yaml

# Create Kube unit
cat <<EOF | sudo tee /etc/containers/systemd/ochami.kube
[Unit]
Description=OpenCHAMI Services (Podman Quadlet)
Wants=network-online.target
After=network-online.target

[Service]
TimeoutStartSec=900

[Kube]
Yaml=/etc/containers/systemd/ochami.yaml
Network=host
EOF

echo "Reloading systemd and starting ochami service..."
sudo systemctl daemon-reload
sudo systemctl restart ochami

rm -f "$VALUES_FILE"

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

# 6. Create VMs
if [ "$NUM_VMS" -gt 0 ]; then
    step "Creating $NUM_VMS VMs..."
    create_and_register_vms "$NUM_VMS" "$HOST_IP"
fi

# 7. Final Instructions
info "=== Deployment Complete ==="
echo "  Stork DHCP Monitor: http://localhost:${STORK_PORT}/ (login: admin/admin)"
echo ""
echo "You can now verify the services are running:"
echo "  sudo systemctl status ochami"
echo "  sudo podman ps"
echo ""
if [ "$NUM_VMS" -gt 0 ]; then
    echo "To connect to the VM console, run:"
    for i in $(seq 0 $((NUM_VMS - 1))); do
        echo "  sudo virsh start --console virtual-compute-node-$i"
    done
else
    echo "To create and boot a VM, run:"
    echo "  sudo ./scripts/create_vm.sh"
    echo "  sudo virsh start --console virtual-compute-node"
fi
