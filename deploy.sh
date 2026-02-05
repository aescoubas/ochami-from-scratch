#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== OpenCHAMI Minikube Deployment Script ===${NC}"

# Arguments
FORCE_REBUILD=false
DHCP_START=""
DHCP_END=""
DHCP_NETMASK=""
PXE_INTERFACE="virbr-pxe"
PXE_IP="192.168.100.2"
PXE_CIDR="24"
PHY_IFACE=""
MODE="libvirt"
NUM_VMS=0
ORCHESTRATOR="minikube"
CONTAINER_TOOL="docker"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rebuild) FORCE_REBUILD=true ;;
        --dhcp-start) DHCP_START="$2"; shift ;;
        --dhcp-end) DHCP_END="$2"; shift ;;
        --dhcp-netmask) DHCP_NETMASK="$2"; shift ;;
        --interface) PXE_INTERFACE="$2"; shift ;;
        --ip) PXE_IP="$2"; shift ;;
        --cidr) PXE_CIDR="$2"; shift ;;
        --phy-iface) PHY_IFACE="$2"; shift ;;
        --mode) MODE="$2"; shift ;;
        --vms) NUM_VMS="$2"; shift ;;
        --orchestrator) ORCHESTRATOR="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ "$ORCHESTRATOR" == "podman" ]; then
    CONTAINER_TOOL="sudo podman"
fi

if [[ "$MODE" != "libvirt" && "$MODE" != "hardware" ]]; then
    echo "Error: --mode must be 'libvirt' or 'hardware'." >&2
    exit 1
fi

# Validate that if one DHCP range parameter is set, the other is too
if { [ -n "$DHCP_START" ] && [ -z "$DHCP_END" ]; } || { [ -z "$DHCP_START" ] && [ -n "$DHCP_END" ]; }; then
    echo "Error: --dhcp-start and --dhcp-end must be specified together." >&2
    exit 1
fi

if [ "$FORCE_REBUILD" = true ]; then
    echo "Force rebuild enabled."
fi

# Helper to increment IP address
next_ip() {
    IP=$1
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
}


# 0. Check and Install Prerequisites (System-level for 'none' driver)
./scripts/install_prerequisites.sh

# 1. Check Prerequisites
echo -e "${GREEN}--> Checking prerequisites for $ORCHESTRATOR...${NC}"

if [ "$ORCHESTRATOR" == "podman" ]; then
    command -v podman >/dev/null 2>&1 || { echo "podman is required but not installed. Aborting." >&2; exit 1; }
    command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }
else
    command -v minikube >/dev/null 2>&1 || { echo "minikube is required but not installed. Aborting." >&2; exit 1; }
    #command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
    command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }
    command -v docker >/dev/null 2>&1 || { echo "docker is required but not installed. Aborting." >&2; exit 1; }
fi

if [ "$MODE" == "libvirt" ]; then
    command -v virt-install >/dev/null 2>&1 || { echo "virt-install is required for libvirt mode but not installed. Aborting." >&2; exit 1; }
fi

# 2. Start Minikube
if [ "$ORCHESTRATOR" == "minikube" ]; then
    echo -e "${GREEN}--> Ensuring Minikube is running...${NC}"
    if ! minikube status | grep -q "Running"; then
        echo "Starting Minikube..."
        sudo -E minikube start --driver=none --memory=4096 --cpus=2
        # Fix permissions for the user
        sudo chown -R $USER:$USER $HOME/.minikube $HOME/.kube
    else
        echo "Minikube is already running."
    fi
fi

# Helper functions
image_exists_in_minikube() {
    minikube image ls | grep -q "$1"
}

image_exists_locally() {
    docker image inspect "$1" >/dev/null 2>&1
}

# 3. Build and Load Images
echo -e "${GREEN}--> Building and loading images...${NC}"

export CONTAINER_TOOL
export ORCHESTRATOR

# 3.1 HTTP Server and TFTP Server
HTTP_IMAGE="localhost/http-server:latest"
EMULATOR_IMAGE="localhost/redfish-emulator:latest"
# Check: In podman, check local storage. In minikube, check minikube cache.
if [ "$ORCHESTRATOR" == "podman" ]; then
    # Simple check if image exists in podman
    IMAGE_CHECK_CMD="$CONTAINER_TOOL image exists"
else
    IMAGE_CHECK_CMD="image_exists_in_minikube"
fi

if $FORCE_REBUILD || ! $IMAGE_CHECK_CMD "$HTTP_IMAGE" || ! $IMAGE_CHECK_CMD "$EMULATOR_IMAGE"; then
    echo "Building http-server (SLES) and redfish-emulator..."
    ./scripts/build_and_load_images.sh
else
    echo "Images $HTTP_IMAGE and $EMULATOR_IMAGE found. Skipping build."
fi

TFTP_IMAGE="localhost/tftp:latest"
if $FORCE_REBUILD || ! $IMAGE_CHECK_CMD "$TFTP_IMAGE"; then
    echo "Building tftp server..."
    $CONTAINER_TOOL build -t "$TFTP_IMAGE" ochami-helm/tftp/
    if [ "$ORCHESTRATOR" == "minikube" ]; then
        echo "Loading $TFTP_IMAGE into Minikube..."
        minikube image load "$TFTP_IMAGE"
    fi
else
    echo "Image $TFTP_IMAGE found. Skipping build."
fi

# 3.2 Microservices
# Source the build functions
if [ -f scripts/build_microservices.sh ]; then
    source scripts/build_microservices.sh
else
    echo "Error: scripts/build_microservices.sh not found."
    exit 1
fi

MS_IMAGES=("localhost/smd:local-smd" "localhost/bss:local-bss")

for img in "${MS_IMAGES[@]}"; do
    if $FORCE_REBUILD || ! $IMAGE_CHECK_CMD "$img"; then
        echo "Image $img not found (or rebuild forced)."
        
        # Check locally (docker daemon or podman storage)
        # Note: build_microservices.sh builds to the local daemon ($CONTAINER_TOOL)
        # So we just need to ensure it's built.
        
        echo "Building $img locally..."
        
        # Parse repo and tag
        # img format: localhost/name:tag
        REPO_TAG=${img#localhost/}
        NAME=${REPO_TAG%%:*}
        TAG=${REPO_TAG##*:}
        
        # Map logical name to build function
        FUNC="build_${NAME}"
        
        if declare -f "$FUNC" > /dev/null; then
            $FUNC "$TAG"
            
            # Fix for coresmd tagging mismatch (it builds local-build but we need local-coresmd)
            if [[ "$NAME" == "coresmd" ]]; then
                # Check if target exists
                if ! $CONTAINER_TOOL image inspect "$img" >/dev/null 2>&1; then
                    if $CONTAINER_TOOL image inspect "localhost/coresmd:local-build" >/dev/null 2>&1; then
                        echo "Retagging coresmd:local-build to $TAG..."
                        $CONTAINER_TOOL tag "localhost/coresmd:local-build" "$img"
                    fi
                fi
            fi
        else
            echo "Error: Build function '$FUNC' not found for $img."
            exit 1
        fi
        
        if [ "$ORCHESTRATOR" == "minikube" ]; then
            echo "Loading $img into Minikube..."
            docker save "$img" | minikube image load -
        fi
    else
        echo "Image $img found. Skipping."
    fi
done

# 4. Configure Network
echo -e "${GREEN}--> Configuring PXE network on Minikube (Mode: $MODE)...${NC}"

if [ "$MODE" == "hardware" ]; then
    # Disable dnsmasq from libvirt (if present) to avoid conflicts on port 67
    if command -v virsh >/dev/null 2>&1; then
        echo -e "${GREEN}--> Checking for conflicting libvirt dnsmasq...${NC}"
        if virsh net-info default >/dev/null 2>&1; then
            if virsh net-info default | grep "Active: *yes" >/dev/null 2>&1; then
                echo "Stopping libvirt default network..."
                sudo virsh net-destroy default || echo "Failed to stop default network, maybe not running."
            fi
            if virsh net-list --autostart | grep "default" >/dev/null 2>&1; then
                echo "Disabling autostart for libvirt default network..."
                sudo virsh net-autostart --disable default || echo "Failed to disable autostart for default network."
            fi
        else
            echo "Libvirt default network not found or not active. No action needed."
        fi
    else
        echo "virsh command not found. Skipping libvirt dnsmasq check."
    fi

    # Auto-adjust interface if using defaults and phy-iface is provided
    # In hardware mode, we don't create virbr-pxe, so we should use the physical interface directly
    if [ "$PXE_INTERFACE" == "virbr-pxe" ] && [ -n "$PHY_IFACE" ]; then
        echo -e "${GREEN}--> Hardware Mode: Using physical interface $PHY_IFACE directly (replacing virbr-pxe).${NC}"
        PXE_INTERFACE="$PHY_IFACE"
        # We don't need to bridge it to itself, so clear PHY_IFACE to avoid setup_minikube_net.sh trying to bridge it
        PHY_IFACE=""
    fi

    if [ "$PXE_INTERFACE" == "virbr-pxe" ]; then
         echo -e "${GREEN}Warning: Mode is hardware but interface is default 'virbr-pxe'.${NC}"
         echo "Since libvirt network creation is skipped in hardware mode, 'virbr-pxe' will likely not exist."
         echo "Ensure you provide a valid interface with --interface or that 'virbr-pxe' is created manually."
    fi
fi

if [ "$MODE" == "libvirt" ]; then
    if [ "$PXE_INTERFACE" == "virbr-pxe" ]; then
        if ! virsh net-info pxe-net >/dev/null 2>&1; then
            echo "Defining pxe-net network..."
            virsh net-define <(cat <<EOF
<network>
  <name>pxe-net</name>
  <uuid>c8f874f7-dd7a-465c-862a-ec30f41ac4bb</uuid>
  <bridge name='virbr-pxe' stp='on' delay='0'/>
  <mac address='52:54:00:d8:3f:37'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
  </ip>
</network>
EOF
)
            virsh net-start pxe-net
            virsh net-autostart pxe-net
        fi
    else
        echo "Using custom interface: $PXE_INTERFACE. Skipping libvirt network creation."
    fi
else
    echo "Hardware mode selected. Skipping libvirt network creation."
fi

# Run the network setup script
./scripts/setup_minikube_net.sh "$PXE_INTERFACE" "$PXE_IP" "$PXE_CIDR" "$PHY_IFACE"

# 5. Deploy
echo -e "${GREEN}--> Deploying OpenCHAMI (Orchestrator: $ORCHESTRATOR)...${NC}"

HOST_IP="$PXE_IP"
echo "Using Host IP for PXE boot: $HOST_IP"

# Set defaults for DHCP if not provided
if [ -z "$DHCP_START" ]; then
    DHCP_START="192.168.100.100"
    DHCP_END="192.168.100.200"
fi
if [ -z "$DHCP_NETMASK" ]; then
    DHCP_NETMASK="255.255.255.0"
fi

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
projectRoot: "$(pwd)"
httpServer:
  hostNetwork: true
  port: 80

bss:
  ipxe:
    server: "$HOST_IP"
  advertise_address: "$HOST_IP"

kea:
  db:
    host: "ochami-postgres"
    port: 5432
    name: "kea"
    user: "kea-user"
    password: "CHANGEME" # Ensure this matches values.yaml or is overridden

bootScriptUrl: "http://$HOST_IP/boot.ipxe"
EOF

if [ "$NUM_VMS" -gt 0 ]; then
cat <<EOF >> "$VALUES_FILE"
emulator:
  enabled: true
  replicas: $NUM_VMS
EOF
fi

if [ "$ORCHESTRATOR" == "minikube" ]; then
    # Create namespace
    minikube kubectl -- create ns ochami || true

    # Wait for default service account (avoid race condition)
    echo "Waiting for default service account in ochami namespace..."
    for i in {1..30}; do
        if minikube kubectl -- get sa default -n ochami >/dev/null 2>&1; then
            break
        fi
        echo "Waiting for ServiceAccount..."
        sleep 1
    done

    # Restart http-server to pick up new image
    minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=http-server --wait=false 2>/dev/null || true
    minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=tftp --wait=false 2>/dev/null || true
    minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=kea 2>/dev/null || true
    minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=postgres 2>/dev/null || true
    minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=smd 2>/dev/null || true
    minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=bss 2>/dev/null || true

    echo "Deploying Helm chart (waiting for services to become ready)..."
    helm upgrade --install ochami ./ochami-helm -n ochami -f ochami-helm/values-pxe.yaml -f "$VALUES_FILE" --wait --timeout 10m0s

elif [ "$ORCHESTRATOR" == "podman" ]; then
    echo "Generating Podman Quadlet configuration..."
    
    # Ensure firewall allows traffic on the PXE bridge
    if systemctl is-active --quiet firewalld; then
        echo "Configuring firewall for $PXE_INTERFACE..."
        sudo firewall-cmd --zone=trusted --add-interface="$PXE_INTERFACE" --permanent
        sudo firewall-cmd --reload
    fi
    
    TEMPLATE_OUT="/tmp/ochami.yaml"
    # Generate YAML from Helm
    helm template ochami ./ochami-helm -n ochami -f ochami-helm/values-pxe.yaml -f "$VALUES_FILE" > "$TEMPLATE_OUT"
    
    # Patch YAML for Host Networking (Connection Strings)
    # 1. Postgres host: ochami-postgres -> localhost
    # 2. SMD URL (in BSS): ochami-smd... -> localhost
    # 3. BSS URL (if any): ochami-bss... -> localhost
    
    # We use sed to replace occurrences.
    # Warning: This is a bit brittle but necessary without DNS aliases.
    sed -i 's/ochami-postgres/localhost/g' "$TEMPLATE_OUT"
    sed -i 's/ochami-smd.ochami.svc.cluster.local/localhost/g' "$TEMPLATE_OUT"
    sed -i 's/ochami-bss.ochami.svc.cluster.local/localhost/g' "$TEMPLATE_OUT"
    
    # Reorder pods for Quadlet dependencies
    if [ -f scripts/quadlet_reorder.py ]; then
        echo "Reordering Quadlet YAML..."
        python3 scripts/quadlet_reorder.py "$TEMPLATE_OUT" "$TEMPLATE_OUT"
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
    
    echo "Waiting for services to start..."
    # Wait for SMD (port 27779) and BSS (port 27778)
    for i in {1..60}; do
        if curl -s "http://localhost:27779/hsm/v2/service/ready" >/dev/null; then
            echo "SMD is ready."
            break
        fi
        echo "Waiting for SMD..."
        sleep 2
    done
fi

rm -f "$VALUES_FILE"

# 5b. Configure BSS Default Boot Parameters
echo -e "${GREEN}--> Configuring BSS Default Boot Parameters...${NC}"
BSS_IP=""

if [ "$ORCHESTRATOR" == "minikube" ]; then
    for i in {1..30}; do
        BSS_IP=$(minikube kubectl -- get svc ochami-bss -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
        if [ -n "$BSS_IP" ]; then
            break
        fi
        echo "Waiting for BSS service IP..."
        sleep 2
    done
elif [ "$ORCHESTRATOR" == "podman" ]; then
    BSS_IP="$HOST_IP" # Host network
fi

if [ -z "$BSS_IP" ]; then
    echo "Error: Could not determine BSS ClusterIP."
    exit 1
fi

echo "BSS Service IP: $BSS_IP"
ARTIFACTS_URL="http://$HOST_IP:30080/artifacts"

echo "Registering 'Default' boot parameters in BSS..."
# Retry loop for BSS API availability
for i in {1..30}; do
    if curl -s -f -X PUT "http://${BSS_IP}:27778/boot/v1/bootparameters" \
      -H "Content-Type: application/json" \
      -d "{
        \"hosts\": [\"Default\"],
        \"kernel\": \"${ARTIFACTS_URL}/vmlinuz-lts\",
        \"initrd\": \"${ARTIFACTS_URL}/initramfs-lts\",
        \"params\": \"console=ttyS0 ip=dhcp rd.neednet=1 root=live:${ARTIFACTS_URL}/rootfs.squashfs\"
      }" >/dev/null; then
        echo "Successfully registered Default boot parameters."
        break
    else
        echo "Waiting for BSS API to be ready..."
        sleep 2
    fi
done

# 6. Create VMs if requested
if [ "$NUM_VMS" -gt 0 ]; then
    echo -e "${GREEN}--> Creating $NUM_VMS VMs...${NC}"
    # Start assigning static IPs for registered nodes from .50
    CURRENT_IP_OCTET=50
    
    # Export ARTIFACTS_URL for the registration script to use
    export ARTIFACTS_URL
    export HOST_IP
    
    for i in $(seq 0 $((NUM_VMS - 1))); do
        VM_NAME="virtual-compute-node-$i"
        # Format: x0c0s{i}b0n0 (Vary slot to ensure unique BMCs)
        COMP_ID="x0c0s${i}b0n0"
        STATIC_IP="192.168.100.${CURRENT_IP_OCTET}"
        
        echo "Creating $VM_NAME..."
        sudo ./scripts/create_vm.sh --name "$VM_NAME"
        
        echo "Registering $VM_NAME ($COMP_ID) with IP $STATIC_IP..."
        # Wait a moment for VM to be recognized by libvirt fully if needed, though create_vm usually blocks until start
        sleep 2
        
        # Call the registration script
        # Usage: ./scripts/register_local_vm.sh <vm-name> <desired-ip> [COMPONENT_ID] [NID]
        # Run as user (not sudo) because it needs access to minikube kubectl context
        ./scripts/register_local_vm.sh "$VM_NAME" "$STATIC_IP" "$COMP_ID" "$((i+1))" || echo "Warning: Registration failed for $VM_NAME"

        CURRENT_IP_OCTET=$((CURRENT_IP_OCTET + 1))
        
        # Reboot the VM to force a fresh PXE boot now that it's registered
        echo "Restarting $VM_NAME to pick up new configuration..."
        sudo virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
        sudo virsh start "$VM_NAME" >/dev/null 2>&1 || true
    done
fi

# 7. Final Instructions
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo "You can now verify the pods are running:"
if [ "$ORCHESTRATOR" == "minikube" ]; then
    echo " minikube kubectl -- get pods -n ochami"
else
    echo " sudo systemctl status ochami"
    echo " sudo podman ps"
fi
echo ""
if [ "$NUM_VMS" -gt 0 ]; then
    echo "To start the VMs and connect to the console, run:"
    for i in $(seq 0 $((NUM_VMS - 1))); do
        echo "  sudo virsh start --console virtual-compute-node-$i"
    done
else
    echo "To create and boot a VM, run:"
    echo "  sudo ./scripts/create_vm.sh"
    echo "  sudo virsh start --console virtual-compute-node"
fi
