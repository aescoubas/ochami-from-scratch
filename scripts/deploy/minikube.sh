#!/bin/bash
set -e

# scripts/deploy/minikube.sh — Deploy OpenCHAMI using Minikube

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

# --- Help ---
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Deploy OpenCHAMI using Minikube with the 'none' driver."
    echo ""
    add_common_deploy_args_help
}

if $IS_MACOS && [ "$(id -u)" -eq 0 ]; then
    error "Minikube deployment on macOS must be run as a regular user (do not use sudo)."
    exit 1
fi

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

info "=== OpenCHAMI Minikube Deployment ==="

if [ "$FORCE_REBUILD" = true ]; then
    echo "Force rebuild enabled."
fi

# 0. Install Prerequisites
"$PROJECT_ROOT/scripts/install_prerequisites.sh"

# 1. Check Prerequisites
step "Checking prerequisites for minikube..."
require_command minikube
require_command helm
require_command docker
if ! $IS_MACOS && [ "$MODE" == "libvirt" ]; then
    require_command virt-install "virt-install is required for libvirt mode but not installed. Aborting."
fi

# 2. Start Minikube
step "Ensuring Minikube is running..."
if ! minikube status | grep -q "Running"; then
    echo "Starting Minikube..."
    if $IS_MACOS; then
        minikube start --driver=docker --memory=4096 --cpus=2
    else
        sudo -E minikube start --driver=none --memory=4096 --cpus=2
        relax_permissions "$HOME/.minikube" "$HOME/.kube"
    fi
else
    echo "Minikube is already running."
fi

# 3. Build and Load Images
step "Building and loading images..."
build_images_if_needed "docker" "minikube" "$FORCE_REBUILD"

# 4. Configure Network
step "Configuring PXE network (Mode: $MODE)..."

if $IS_MACOS; then
    echo "macOS: Skipping host network configuration (Minikube Docker driver manages networking)."
    HOST_IP=$(minikube ip 2>/dev/null || echo "127.0.0.1")
    echo "Using Minikube IP: $HOST_IP"
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

    # 4b. Check for DHCP port conflicts (e.g. dnsmasq from libvirt)
    check_dhcp_port_conflict "$PXE_INTERFACE"
fi

# 5. Deploy
step "Deploying OpenCHAMI (Minikube)..."
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
bootScriptUrl: "http://$HOST_IP/boot/v1/bootscript?mac=\${mac}"
EOF

if [ "$NUM_VMS" -gt 0 ]; then
cat <<EOF >> "$VALUES_FILE"
emulator:
  enabled: true
  replicas: $NUM_VMS
EOF
if $IS_MACOS; then
cat <<EOF >> "$VALUES_FILE"
  libvirtSocket:
    enabled: false
EOF
fi
fi

# Create namespace
minikube kubectl -- create ns ochami || true

# Wait for default service account
echo "Waiting for default service account in ochami namespace..."
for i in {1..30}; do
    if minikube kubectl -- get sa default -n ochami >/dev/null 2>&1; then
        break
    fi
    echo "Waiting for ServiceAccount..."
    sleep 1
done

# Restart pods to pick up new images
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=http-server --wait=false 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=tftp --wait=false 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=kea 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=postgres 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=smd 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=bss 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=cloud-init 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=pcs 2>/dev/null || true
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=stork-server 2>/dev/null || true

echo "Deploying Helm chart (waiting for services to become ready)..."
helm upgrade --install ochami "$PROJECT_ROOT/ochami-helm" -n ochami -f "$PROJECT_ROOT/ochami-helm/values-pxe.yaml" -f "$VALUES_FILE" --wait --timeout 10m0s

rm -f "$VALUES_FILE"

# 5b. Configure BSS
step "Configuring BSS Default Boot Parameters..."
BSS_IP=""
for i in {1..30}; do
    BSS_IP=$(minikube kubectl -- get svc ochami-bss -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -n "$BSS_IP" ]; then
        break
    fi
    echo "Waiting for BSS service IP..."
    sleep 2
done

if [ -z "$BSS_IP" ]; then
    error "Could not determine BSS ClusterIP."
    exit 1
fi

register_bss_defaults "$BSS_IP" "$HOST_IP" "ds=nocloud-net;s=http://${HOST_IP}:${HTTP_PORT}/cloud-init/"

# 5c. Discover/register hardware nodes
if [ "$DISCOVERY_METHOD" == "magellan" ]; then
    step "Running Magellan dynamic discovery..."
    export ORCHESTRATOR="minikube"
    run_magellan_discovery "$HOST_IP"
elif [ -n "$NODES_FILE" ]; then
    step "Registering hardware nodes from $NODES_FILE..."
    validate_nodes_file "$NODES_FILE"
    export ORCHESTRATOR="minikube"
    register_hardware_nodes_from_file "$NODES_FILE" "$HOST_IP"
fi

# 6. Create VMs
if [ "$NUM_VMS" -gt 0 ]; then
    if $IS_MACOS; then
        warn "VM creation via libvirt is not available on macOS."
        echo "Use ./scripts/register_hardware_node.sh to register physical nodes instead."
    elif [ "$DISCOVERY_METHOD" == "magellan" ]; then
        step "Creating $NUM_VMS VMs (Magellan discovery mode)..."
        create_vms_only "$NUM_VMS"
        step "Running Magellan discovery after VM creation..."
        export ORCHESTRATOR="minikube"
        run_magellan_discovery "$HOST_IP"
    else
        step "Creating $NUM_VMS VMs..."
        create_and_register_vms "$NUM_VMS" "$HOST_IP"
    fi
fi

# 7. Final Instructions
info "=== Deployment Complete ==="
echo "  Stork DHCP Monitor: http://localhost:${STORK_PORT}/ (login: admin/admin)"
echo ""
echo "You can now verify the pods are running:"
echo "  minikube kubectl -- get pods -n ochami"
echo ""
if $IS_MACOS; then
    echo "To register a hardware node:"
    echo "  ./scripts/register_hardware_node.sh <MAC_ADDRESS> <IP_ADDRESS> [COMPONENT_ID] [NID]"
    echo ""
    echo "Note: VM creation via libvirt is not available on macOS."
elif [ "$NUM_VMS" -gt 0 ]; then
    echo "To connect to the VM console, run:"
    for i in $(seq 0 $((NUM_VMS - 1))); do
        echo "  sudo virsh start --console virtual-compute-node-$i"
    done
else
    echo "To create and boot a VM, run:"
    echo "  sudo ./scripts/create_vm.sh"
    echo "  sudo virsh start --console virtual-compute-node"
fi
