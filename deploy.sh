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
WHITELIST_MACS=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rebuild) FORCE_REBUILD=true ;;
        --dhcp-start) DHCP_START="$2"; shift ;;
        --dhcp-end) DHCP_END="$2"; shift ;;
        --dhcp-netmask) DHCP_NETMASK="$2"; shift ;;
        --whitelist-macs) WHITELIST_MACS="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

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
./install_prerequisites.sh

# 1. Check Prerequisites
echo -e "${GREEN}--> Checking prerequisites...${NC}"
command -v minikube >/dev/null 2>&1 || { echo "minikube is required but not installed. Aborting." >&2; exit 1; }
#command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed. Aborting." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker is required but not installed. Aborting." >&2; exit 1; }
command -v virt-install >/dev/null 2>&1 || { echo "virt-install is required but not installed. Aborting." >&2; exit 1; }

# 2. Start Minikube
echo -e "${GREEN}--> Ensuring Minikube is running...${NC}"
if ! minikube status | grep -q "Running"; then
    echo "Starting Minikube..."
    sudo -E minikube start --driver=none --memory=4096 --cpus=2
    # Fix permissions for the user
    sudo chown -R $USER:$USER $HOME/.minikube $HOME/.kube
else
    echo "Minikube is already running."
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

# 3.1 HTTP Server
HTTP_IMAGE="localhost/http-server:latest"
if $FORCE_REBUILD || ! image_exists_in_minikube "$HTTP_IMAGE"; then
    echo "Building http-server (SLES)..."
    ./build_and_load_http_server_sles.sh
else
    echo "Image $HTTP_IMAGE found in Minikube. Skipping build/load."
fi

# 3.2 Microservices
# Source the build functions
if [ -f build_microservices.sh ]; then
    source build_microservices.sh
else
    echo "Error: build_microservices.sh not found."
    exit 1
fi

MS_IMAGES=("localhost/smd:local-smd" "localhost/bss:local-bss" "localhost/coresmd:local-coresmd")

for img in "${MS_IMAGES[@]}"; do
    if $FORCE_REBUILD || ! image_exists_in_minikube "$img"; then
        echo "Image $img not found in Minikube (or rebuild forced)."
        
        if $FORCE_REBUILD || ! image_exists_locally "$img"; then
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
                    if ! image_exists_locally "$img"; then
                        if image_exists_locally "localhost/coresmd:local-build"; then
                            echo "Retagging coresmd:local-build to $TAG..."
                            docker tag "localhost/coresmd:local-build" "$img"
                        fi
                    fi
                fi
            else
                echo "Error: Build function '$FUNC' not found for $img."
                exit 1
            fi
        else
             echo "Image $img found locally. Skipping local build."
        fi
        
        echo "Loading $img into Minikube..."
        docker save "$img" | minikube image load -
    else
        echo "Image $img found in Minikube. Skipping."
    fi
done

# 4. Configure Network
echo -e "${GREEN}--> Configuring PXE network on Minikube...${NC}"
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

# Run the network setup script
./setup_minikube_net.sh

# 5. Deploy Helm Chart
echo -e "${GREEN}--> Deploying OpenCHAMI Helm chart...${NC}"
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

# Restart http-server to pick up new image (since tag is latest)
# We delete it BEFORE upgrade so Helm recreates it.
echo "Removing old http-server pod..."
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=http-server --wait=false 2>/dev/null || true

# Install/Upgrade
# Detect Host IP for PXE (Use the IP of the interface with the default route, or fallback to 192.168.100.2)
HOST_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
if [ -z "$HOST_IP" ]; then
    HOST_IP="192.168.100.2"
fi
echo "Using Host IP for PXE boot: $HOST_IP"

# Generate dynamic values file
VALUES_FILE=$(mktemp)
echo "externalIp: \"$HOST_IP\"" > "$VALUES_FILE"

if [ -n "$DHCP_START" ]; then echo "dhcpStart: \"$DHCP_START\"" >> "$VALUES_FILE"; fi
if [ -n "$DHCP_END" ]; then echo "dhcpEnd: \"$DHCP_END\"" >> "$VALUES_FILE"; fi
if [ -n "$DHCP_NETMASK" ]; then echo "dhcpNetmask: \"$DHCP_NETMASK\"" >> "$VALUES_FILE"; fi

if [ -n "$WHITELIST_MACS" ]; then
    echo "dhcpAllocationConfig: |" >> "$VALUES_FILE"
    
    # Use DHCP_START or default
    CURRENT_IP="${DHCP_START:-192.168.100.100}"
    
    IFS=',' read -ra MACS <<< "$WHITELIST_MACS"
    for mac in "${MACS[@]}"; do
        # Trim whitespace
        mac=$(echo "$mac" | xargs)
        echo "  - static: $mac $CURRENT_IP" >> "$VALUES_FILE"
        CURRENT_IP=$(next_ip "$CURRENT_IP")
    done
fi

helm upgrade --install ochami ./ochami-helm -n ochami -f ochami-helm/values-pxe.yaml -f "$VALUES_FILE"

rm -f "$VALUES_FILE"

# 6. Final Instructions
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo "You can now verify the pods are running:"
echo " minikube kubectl -- get pods -n ochami"
echo ""
echo "To create and boot the VM, run:"
echo "  sudo ./create_vm.sh"
echo "  sudo virsh start --console virtual-compute-node"
