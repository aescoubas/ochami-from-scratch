#!/bin/bash
# shellcheck disable=SC2034
# common.sh — Shared function library for OpenCHAMI deploy/teardown scripts
# This file should be sourced, not executed directly.
# SC2034: Variables defined here are used by scripts that source this file.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script should be sourced, not executed directly." >&2
    exit 1
fi

# --- Project Root ---
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$COMMON_DIR/.." && pwd)"

# --- Color Codes ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# --- Default Values ---
DEFAULT_PXE_INTERFACE="virbr-pxe"
DEFAULT_PXE_IP="192.168.100.2"
DEFAULT_PXE_CIDR="24"
DEFAULT_DHCP_START="192.168.100.100"
DEFAULT_DHCP_END="192.168.100.200"
DEFAULT_DHCP_NETMASK="255.255.255.0"
DEFAULT_MODE="libvirt"
DEFAULT_NUM_VMS=0
DEFAULT_VM_NAME="virtual-compute-node"

# Image names
IMAGE_HTTP="localhost/http-server:latest"
IMAGE_TFTP="localhost/tftp:latest"
IMAGE_EMULATOR="localhost/redfish-emulator:latest"
MS_IMAGES=("localhost/smd:local-smd" "localhost/bss:local-bss")

# Database credentials (from ochami-helm/values.yaml)
POSTGRES_USER="ochami"
POSTGRES_PASSWORD="CHANGEME"
SMD_DB_NAME="hmsds"
SMD_DB_USER="smd-user"
SMD_DB_PASSWORD="CHANGEME"
BSS_DB_NAME="bssdb"
BSS_DB_USER="bss-user"
BSS_DB_PASSWORD="CHANGEME"
KEA_DB_NAME="kea"
KEA_DB_USER="kea-user"
KEA_DB_PASSWORD="CHANGEME"
HYDRA_DB_PASSWORD="CHANGEME"

# Service ports
SMD_PORT=27779
BSS_PORT=27778
POSTGRES_PORT=5432
HTTP_PORT=80
TFTP_PORT=69

# --- Logging ---

info() {
    echo -e "${GREEN}$*${NC}"
}

warn() {
    echo -e "${YELLOW}Warning: $*${NC}" >&2
}

error() {
    echo -e "${RED}Error: $*${NC}" >&2
}

step() {
    echo -e "${GREEN}--> $*${NC}"
}

# --- Validation ---

validate_ip() {
    local ip="$1"
    local label="${2:-IP address}"
    if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error "$label '$ip' is not a valid IP address."
        return 1
    fi
    local IFS='.'
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if (( octet > 255 )); then
            error "$label '$ip' has an octet out of range (0-255)."
            return 1
        fi
    done
    return 0
}

validate_cidr() {
    local cidr="$1"
    if ! [[ "$cidr" =~ ^[0-9]+$ ]] || (( cidr < 0 || cidr > 32 )); then
        error "CIDR '$cidr' must be an integer between 0 and 32."
        return 1
    fi
    return 0
}

validate_positive_int() {
    local val="$1"
    local label="${2:-value}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        error "$label '$val' must be a non-negative integer."
        return 1
    fi
    return 0
}

validate_interface_exists() {
    local iface="$1"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        error "Interface '$iface' does not exist."
        return 1
    fi
    return 0
}

# --- Utilities ---

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    local cmd="$1"
    local msg="${2:-$cmd is required but not installed. Aborting.}"
    if ! command_exists "$cmd"; then
        error "$msg"
        exit 1
    fi
}

wait_for_url() {
    local url="$1"
    local label="${2:-service}"
    local max_attempts="${3:-60}"
    local interval="${4:-2}"

    for i in $(seq 1 "$max_attempts"); do
        if curl -s -f "$url" >/dev/null 2>&1; then
            echo "$label is ready."
            return 0
        fi
        echo "Waiting for $label... ($i/$max_attempts)"
        sleep "$interval"
    done
    error "$label did not become ready after $((max_attempts * interval)) seconds."
    return 1
}

next_ip() {
    local ip="$1"
    local IFS='.'
    read -r a b c d <<< "$ip"
    local ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d + 1 ))
    printf '%d.%d.%d.%d\n' $(( (ip_int >> 24) & 255 )) $(( (ip_int >> 16) & 255 )) $(( (ip_int >> 8) & 255 )) $(( ip_int & 255 ))
}

# --- Image Building ---

build_images_if_needed() {
    local container_tool="$1"
    local orchestrator="$2"
    local force_rebuild="$3"

    export CONTAINER_TOOL="$container_tool"
    export ORCHESTRATOR="$orchestrator"

    # Helper functions
    image_exists_in_minikube() {
        minikube image ls | grep -q "$1"
    }

    local IMAGE_CHECK_CMD
    if [ "$orchestrator" == "podman" ]; then
        IMAGE_CHECK_CMD="$container_tool image exists"
    elif [ "$orchestrator" == "docker-compose" ]; then
        IMAGE_CHECK_CMD="docker image inspect"
    else
        IMAGE_CHECK_CMD="image_exists_in_minikube"
    fi

    # Build HTTP Server, Redfish Emulator
    local need_build=false
    if [ "$force_rebuild" = true ]; then
        need_build=true
    elif [ "$orchestrator" == "docker-compose" ]; then
        if ! docker image inspect "$IMAGE_HTTP" >/dev/null 2>&1 || ! docker image inspect "$IMAGE_EMULATOR" >/dev/null 2>&1; then
            need_build=true
        fi
    elif [ "$orchestrator" == "podman" ]; then
        if ! $container_tool image exists "$IMAGE_HTTP" || ! $container_tool image exists "$IMAGE_EMULATOR"; then
            need_build=true
        fi
    else
        if ! image_exists_in_minikube "$IMAGE_HTTP" || ! image_exists_in_minikube "$IMAGE_EMULATOR"; then
            need_build=true
        fi
    fi

    if [ "$need_build" = true ]; then
        echo "Building http-server (SLES) and redfish-emulator..."
        "$PROJECT_ROOT/scripts/build_and_load_images.sh"
    else
        echo "Images $IMAGE_HTTP and $IMAGE_EMULATOR found. Skipping build."
    fi

    # Build TFTP
    local need_tftp=false
    if [ "$force_rebuild" = true ]; then
        need_tftp=true
    elif [ "$orchestrator" == "docker-compose" ]; then
        if ! docker image inspect "$IMAGE_TFTP" >/dev/null 2>&1; then
            need_tftp=true
        fi
    elif [ "$orchestrator" == "podman" ]; then
        if ! $container_tool image exists "$IMAGE_TFTP"; then
            need_tftp=true
        fi
    else
        if ! image_exists_in_minikube "$IMAGE_TFTP"; then
            need_tftp=true
        fi
    fi

    if [ "$need_tftp" = true ]; then
        echo "Building tftp server..."
        $container_tool build -t "$IMAGE_TFTP" "$PROJECT_ROOT/ochami-helm/tftp/"
        if [ "$orchestrator" == "minikube" ]; then
            echo "Loading $IMAGE_TFTP into Minikube..."
            minikube image load "$IMAGE_TFTP"
        fi
    else
        echo "Image $IMAGE_TFTP found. Skipping build."
    fi

    # Build Microservices
    if [ -f "$PROJECT_ROOT/scripts/build_microservices.sh" ]; then
        source "$PROJECT_ROOT/scripts/build_microservices.sh"
    else
        error "scripts/build_microservices.sh not found."
        exit 1
    fi

    for img in "${MS_IMAGES[@]}"; do
        local need_ms=false
        if [ "$force_rebuild" = true ]; then
            need_ms=true
        elif [ "$orchestrator" == "docker-compose" ]; then
            if ! docker image inspect "$img" >/dev/null 2>&1; then
                need_ms=true
            fi
        elif [ "$orchestrator" == "podman" ]; then
            if ! $container_tool image exists "$img"; then
                need_ms=true
            fi
        else
            if ! image_exists_in_minikube "$img"; then
                need_ms=true
            fi
        fi

        if [ "$need_ms" = true ]; then
            echo "Image $img not found (or rebuild forced)."
            echo "Building $img locally..."

            local REPO_TAG="${img#localhost/}"
            local NAME="${REPO_TAG%%:*}"
            local TAG="${REPO_TAG##*:}"
            local FUNC="build_${NAME}"

            if declare -f "$FUNC" > /dev/null; then
                $FUNC "$TAG"

                if [[ "$NAME" == "coresmd" ]]; then
                    if ! $container_tool image inspect "$img" >/dev/null 2>&1; then
                        if $container_tool image inspect "localhost/coresmd:local-build" >/dev/null 2>&1; then
                            echo "Retagging coresmd:local-build to $TAG..."
                            $container_tool tag "localhost/coresmd:local-build" "$img"
                        fi
                    fi
                fi
            else
                error "Build function '$FUNC' not found for $img."
                exit 1
            fi

            if [ "$orchestrator" == "minikube" ]; then
                echo "Loading $img into Minikube..."
                docker save "$img" | minikube image load -
            fi
        else
            echo "Image $img found. Skipping."
        fi
    done
}

# --- Network Configuration ---

configure_hardware_network() {
    local pxe_interface="$1"
    local phy_iface="$2"

    # Disable dnsmasq from libvirt (if present) to avoid conflicts on port 67
    if command_exists virsh; then
        step "Checking for conflicting libvirt dnsmasq..."
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
    if [ "$pxe_interface" == "virbr-pxe" ] && [ -n "$phy_iface" ]; then
        step "Hardware Mode: Using physical interface $phy_iface directly (replacing virbr-pxe)."
        echo "$phy_iface"
        return 0
    fi

    if [ "$pxe_interface" == "virbr-pxe" ]; then
        warn "Mode is hardware but interface is default 'virbr-pxe'."
        echo "Since libvirt network creation is skipped in hardware mode, 'virbr-pxe' will likely not exist."
        echo "Ensure you provide a valid interface with --interface or that 'virbr-pxe' is created manually."
    fi

    echo "$pxe_interface"
}

configure_libvirt_network() {
    local pxe_interface="$1"

    if [ "$pxe_interface" == "virbr-pxe" ]; then
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
        echo "Using custom interface: $pxe_interface. Skipping libvirt network creation."
    fi
}

configure_firewall() {
    local pxe_interface="$1"
    if systemctl is-active --quiet firewalld; then
        echo "Configuring firewall for $pxe_interface..."
        sudo firewall-cmd --zone=trusted --add-interface="$pxe_interface" --permanent
        sudo firewall-cmd --reload
    fi
}

# --- BSS Registration ---

register_bss_defaults() {
    local bss_ip="$1"
    local host_ip="$2"
    local artifacts_url="http://${host_ip}:${HTTP_PORT}/artifacts"

    echo "BSS Service IP: $bss_ip"
    echo "Registering 'Default' boot parameters in BSS..."

    for i in $(seq 1 30); do
        if curl -s -f -X PUT "http://${bss_ip}:${BSS_PORT}/boot/v1/bootparameters" \
          -H "Content-Type: application/json" \
          -d "{
            \"hosts\": [\"Default\"],
            \"kernel\": \"${artifacts_url}/vmlinuz-lts\",
            \"initrd\": \"${artifacts_url}/initramfs-lts\",
            \"params\": \"console=ttyS0 ip=dhcp rd.neednet=1 root=live:${artifacts_url}/rootfs.squashfs\"
          }" >/dev/null; then
            echo "Successfully registered Default boot parameters."
            return 0
        else
            echo "Waiting for BSS API to be ready... ($i/30)"
            sleep 2
        fi
    done
    error "Failed to register BSS defaults after 60 seconds."
    return 1
}

# --- VM Helpers ---

create_and_register_vms() {
    local num_vms="$1"
    local host_ip="$2"
    local artifacts_url="http://${host_ip}:${HTTP_PORT}/artifacts"
    local current_ip_octet=50

    export ARTIFACTS_URL="$artifacts_url"
    export HOST_IP="$host_ip"

    for i in $(seq 0 $((num_vms - 1))); do
        local vm_name="virtual-compute-node-$i"
        local comp_id="x0c0s${i}b0n0"
        local static_ip="192.168.100.${current_ip_octet}"

        echo "Creating $vm_name..."
        sudo "$PROJECT_ROOT/scripts/create_vm.sh" --name "$vm_name"

        echo "Registering $vm_name ($comp_id) with IP $static_ip..."
        sleep 2

        "$PROJECT_ROOT/scripts/register_local_vm.sh" "$vm_name" "$static_ip" "$comp_id" "$((i+1))" || echo "Warning: Registration failed for $vm_name"

        current_ip_octet=$((current_ip_octet + 1))

        echo "Restarting $vm_name to pick up new configuration..."
        sudo virsh destroy "$vm_name" >/dev/null 2>&1 || true
        sudo virsh start "$vm_name" >/dev/null 2>&1 || true
    done
}

# --- CLI Helpers ---

parse_common_deploy_args() {
    FORCE_REBUILD=false
    DHCP_START=""
    DHCP_END=""
    DHCP_NETMASK=""
    PXE_INTERFACE="$DEFAULT_PXE_INTERFACE"
    PXE_IP="$DEFAULT_PXE_IP"
    PXE_CIDR="$DEFAULT_PXE_CIDR"
    PHY_IFACE=""
    MODE="$DEFAULT_MODE"
    NUM_VMS="$DEFAULT_NUM_VMS"

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
            -h|--help) return 2 ;;
            *) error "Unknown parameter: $1"; exit 1 ;;
        esac
        shift
    done
    return 0
}

validate_common_deploy_args() {
    # Validate mode
    if [[ "$MODE" != "libvirt" && "$MODE" != "hardware" ]]; then
        error "--mode must be 'libvirt' or 'hardware'."
        exit 1
    fi

    # Validate IP
    validate_ip "$PXE_IP" "--ip" || exit 1

    # Validate CIDR
    validate_cidr "$PXE_CIDR" || exit 1

    # Validate VMs
    validate_positive_int "$NUM_VMS" "--vms" || exit 1

    # Validate DHCP range
    if { [ -n "$DHCP_START" ] && [ -z "$DHCP_END" ]; } || { [ -z "$DHCP_START" ] && [ -n "$DHCP_END" ]; }; then
        error "--dhcp-start and --dhcp-end must be specified together."
        exit 1
    fi

    if [ -n "$DHCP_START" ]; then
        validate_ip "$DHCP_START" "--dhcp-start" || exit 1
        validate_ip "$DHCP_END" "--dhcp-end" || exit 1
    fi

    if [ -n "$DHCP_NETMASK" ]; then
        validate_ip "$DHCP_NETMASK" "--dhcp-netmask" || exit 1
    fi

    # Apply defaults
    if [ -z "$DHCP_START" ]; then
        DHCP_START="$DEFAULT_DHCP_START"
        DHCP_END="$DEFAULT_DHCP_END"
    fi
    if [ -z "$DHCP_NETMASK" ]; then
        DHCP_NETMASK="$DEFAULT_DHCP_NETMASK"
    fi
}

add_common_deploy_args_help() {
    cat <<EOF
Common options:
  --rebuild              Force rebuild all container images
  --dhcp-start IP        DHCP pool start (default: $DEFAULT_DHCP_START)
  --dhcp-end IP          DHCP pool end (default: $DEFAULT_DHCP_END)
  --dhcp-netmask MASK    DHCP netmask (default: $DEFAULT_DHCP_NETMASK)
  --interface NAME       PXE interface (default: $DEFAULT_PXE_INTERFACE)
  --ip IP                Host IP on PXE interface (default: $DEFAULT_PXE_IP)
  --cidr N               CIDR prefix (default: $DEFAULT_PXE_CIDR)
  --phy-iface NAME       Physical interface to bridge
  --mode MODE            'libvirt' or 'hardware' (default: $DEFAULT_MODE)
  --vms N                Number of VMs to create (default: $DEFAULT_NUM_VMS)
  -h, --help             Show help
EOF
}

# --- Teardown Helpers ---

destroy_vms() {
    local vm_name="$1"
    step "Removing VMs..."
    local vms_to_delete
    vms_to_delete=$(sudo virsh list --all --name | grep -E "^${vm_name}$|^${vm_name}-[0-9]+$" || true)

    if [ -n "$vms_to_delete" ]; then
        for vm in $vms_to_delete; do
            echo "Removing VM '$vm'..."
            sudo virsh destroy "$vm" >/dev/null 2>&1 || true
            sudo virsh undefine --nvram "$vm"
            echo "VM '$vm' removed."
        done
    else
        echo "No VMs matching '$vm_name' found."
    fi
}

destroy_pxe_network() {
    local net_name="pxe-net"
    step "Removing Network '$net_name'..."
    if sudo virsh net-info "$net_name" >/dev/null 2>&1; then
        sudo virsh net-destroy "$net_name" >/dev/null 2>&1 || true
        sudo virsh net-undefine "$net_name"
        echo "Network removed."
    else
        echo "Network '$net_name' not found."
    fi
}

cleanup_host_networking() {
    local host_iface="${1:-virbr-pxe}"
    local host_ip="${2:-192.168.100.2}"

    if systemctl is-active --quiet firewalld; then
        echo "Restoring firewall rules..."
        sudo firewall-cmd --zone=trusted --remove-interface="$host_iface" --permanent || true
        sudo firewall-cmd --reload
    fi

    if ip link show ochami-dummy >/dev/null 2>&1; then
        step "Removing dummy interface ochami-dummy..."
        sudo ip link delete ochami-dummy
    fi

    if ip addr show "$host_iface" 2>/dev/null | grep -q "inet $host_ip/"; then
        step "Removing IP $host_ip from $host_iface..."
        sudo ip addr del "$host_ip/24" dev "$host_iface"
    fi
}

cleanup_build_artifacts() {
    step "Cleaning up build artifacts..."
    rm -f "$PROJECT_ROOT/ochami-helm/http-server/artifacts/vmlinuz-lts"
    rm -f "$PROJECT_ROOT/ochami-helm/http-server/artifacts/initramfs-lts"
    rm -f "$PROJECT_ROOT/ochami-helm/http-server/artifacts/rootfs.squashfs"
    rm -f /tmp/configure_net.sh 2>/dev/null || true
}

parse_common_teardown_args() {
    REMOVE_IMAGES=false
    VM_NAME="$DEFAULT_VM_NAME"
    SKIP_CONFIRM=false

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --remove-images) REMOVE_IMAGES=true ;;
            --vm-name) VM_NAME="$2"; shift ;;
            -y|--yes) SKIP_CONFIRM=true ;;
            -h|--help) return 2 ;;
            *) error "Unknown parameter: $1"; exit 1 ;;
        esac
        shift
    done
    return 0
}

add_common_teardown_args_help() {
    cat <<EOF
Options:
  --remove-images        Also remove container images
  --vm-name NAME         VM name pattern (default: $DEFAULT_VM_NAME)
  -y, --yes              Skip confirmation
  -h, --help             Show help
EOF
}

confirm_teardown() {
    local method="$1"
    echo -e "${RED}=== OpenCHAMI Teardown ($method) ===${NC}"
    echo "This script will PERMANENTLY DELETE:"
    echo "  - VMs matching: $VM_NAME"
    echo "  - Network: pxe-net"
}

prompt_confirmation() {
    if [ "$SKIP_CONFIRM" = false ]; then
        read -p "Are you sure you want to proceed? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
}

remove_images() {
    local tool="$1"
    shift
    local images=("$@")
    step "Removing container images..."
    for img in "${images[@]}"; do
        if $tool image inspect "$img" >/dev/null 2>&1; then
            $tool rmi "$img" || echo "Failed to remove $img (might be in use or dependent)"
        fi
    done
}
