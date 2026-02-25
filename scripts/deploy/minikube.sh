#!/bin/bash
set -e

# scripts/deploy/minikube.sh — Deploy OpenCHAMI using Minikube

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"
source "$SCRIPT_DIR/lib/pipeline.sh"

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

common_deploy_bootstrap "OpenCHAMI Minikube Deployment" "$@"

# 0. Install Prerequisites
common_install_prerequisites

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
    check_dhcp_port_conflict "$PXE_INTERFACE" "$DHCP_CONFLICT_POLICY"
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

postgres:
  user: "$POSTGRES_USER"
  password: "$POSTGRES_PASSWORD"
  smd_password: "$SMD_DB_PASSWORD"
  bss_password: "$BSS_DB_PASSWORD"
  hydra_password: "$HYDRA_DB_PASSWORD"
  kea_password: "$KEA_DB_PASSWORD"
  pcs_password: "$PCS_DB_PASSWORD"
  stork_password: "$STORK_DB_PASSWORD"

bss:
  ipxe:
    server: "$HOST_IP"
  advertise_address: "$HOST_IP"
  nfdUrl: "http://$HOST_IP/hmi/v1/subscribe"

kea:
  db:
    host: "ochami-postgres"
    port: 5432
    name: "$KEA_DB_NAME"
    user: "$KEA_DB_USER"
    password: "$KEA_DB_PASSWORD"
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

# 5c/6. Discover/register hardware nodes and create VMs
VM_CREATION_SUPPORTED=true
if $IS_MACOS; then
    VM_CREATION_SUPPORTED=false
fi
common_run_post_deploy_flow "minikube" "$HOST_IP" "$VM_CREATION_SUPPORTED"

# 7. Write MCP defaults (minikube-only for now)
MCP_ENV_FILE="$PROJECT_ROOT/.openchami-mcp.env"
cat > "$MCP_ENV_FILE" <<EOF
# Generated by scripts/deploy/minikube.sh
# OpenCHAMI MCP defaults (minikube host reverse proxy)
OPENCHAMI_BASE_URL=http://${HOST_IP}:30080
OPENCHAMI_MCP_MODE=read-only
# Set to true only when you explicitly want mutating operations.
OPENCHAMI_MCP_ENABLE_WRITES=false
EOF

# 7. Final Instructions
info "=== Deployment Complete ==="
echo "  Stork DHCP Monitor: http://localhost:${STORK_PORT}/ (login: admin/admin)"
echo ""
echo "You can now verify the pods are running:"
echo "  minikube kubectl -- get pods -n ochami"
echo ""
echo "MCP server (minikube-only, defaults in .openchami-mcp.env):"
echo "  ./scripts/mcp/run_openchami_mcp.sh --mode read-only"
echo "  OPENCHAMI_MCP_ENABLE_WRITES=true ./scripts/mcp/run_openchami_mcp.sh --mode read-write"
echo ""
common_print_vm_instructions "$VM_CREATION_SUPPORTED"
