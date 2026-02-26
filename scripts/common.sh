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

# Centralized base image definitions for locally maintained Dockerfiles.
# shellcheck disable=SC1091
source "$PROJECT_ROOT/scripts/image-bases.env"

# --- OS Detection ---
OS_TYPE="$(uname -s)"   # "Linux" or "Darwin"
IS_MACOS=false
IS_LINUX=false
[[ "$OS_TYPE" == "Darwin" ]] && IS_MACOS=true
[[ "$OS_TYPE" == "Linux" ]]  && IS_LINUX=true
ARCH_TYPE="$(uname -m)" # "x86_64" or "arm64"

require_linux() {
    if $IS_MACOS; then
        error "$1 is not supported on macOS."
        exit 1
    fi
}

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
DEFAULT_SMD_REF="main"
DEFAULT_BSS_REF="main"
DEFAULT_PCS_REF="main"
DEFAULT_SMD_REPO_URI="https://github.com/aescoubas/ochami-smd.git"
DEFAULT_BSS_REPO_URI="https://github.com/aescoubas/ochami-bss.git"
DEFAULT_PCS_REPO_URI="https://github.com/OpenCHAMI/power-control.git"
DEFAULT_DISCOVERY_METHOD="static"
DEFAULT_DHCP_CONFLICT_POLICY="fail"
DEFAULT_SET_FS_PROTECTED_REGULAR=false

# Image names
IMAGE_HTTP="localhost/http-server:latest"
IMAGE_TFTP="localhost/tftp:latest"
IMAGE_EMULATOR="localhost/redfish-emulator:latest"
IMAGE_STORK_AGENT="localhost/stork-agent:latest"
IMAGE_KEA_SIDECAR="localhost/kea-sidecar:latest"
MS_IMAGES=("localhost/smd:local-smd" "localhost/bss:local-bss" "localhost/pcs:local-pcs")

# Database credentials (from ochami-helm/values.yaml)
POSTGRES_USER="${POSTGRES_USER:-ochami}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
SMD_DB_NAME="hmsds"
SMD_DB_USER="smd-user"
SMD_DB_PASSWORD="${SMD_DB_PASSWORD:-}"
BSS_DB_NAME="bssdb"
BSS_DB_USER="bss-user"
BSS_DB_PASSWORD="${BSS_DB_PASSWORD:-}"
KEA_DB_NAME="kea"
KEA_DB_USER="kea-user"
KEA_DB_PASSWORD="${KEA_DB_PASSWORD:-}"
PCS_DB_NAME="pcsdb"
PCS_DB_USER="pcs-user"
PCS_DB_PASSWORD="${PCS_DB_PASSWORD:-}"
STORK_DB_NAME="stork"
STORK_DB_USER="stork-user"
STORK_DB_PASSWORD="${STORK_DB_PASSWORD:-}"
HYDRA_DB_PASSWORD="${HYDRA_DB_PASSWORD:-}"

# Service ports
SMD_PORT=27779
BSS_PORT=27778
POSTGRES_PORT=5432
HTTP_PORT=80
TFTP_PORT=69
CLOUD_INIT_PORT=27777
PCS_PORT=28007
STORK_PORT=28010
STORK_AGENT_PORT=28011
FS_PROTECTED_REGULAR_STATE_FILE="${FS_PROTECTED_REGULAR_STATE_FILE:-/tmp/openchami-fs-protected-regular.state}"

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

validate_mac() {
    local mac="$1"
    local label="${2:-MAC address}"
    if ! [[ "$mac" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]]; then
        error "$label '$mac' is not a valid MAC address (expected XX:XX:XX:XX:XX:XX)."
        return 1
    fi
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
    if $IS_MACOS; then
        if ! ifconfig "$iface" >/dev/null 2>&1; then
            error "Interface '$iface' does not exist."
            return 1
        fi
    else
        if ! ip link show "$iface" >/dev/null 2>&1; then
            error "Interface '$iface' does not exist."
            return 1
        fi
    fi
    return 0
}

# --- CSV Validation ---

validate_nodes_file() {
    local file="$1"
    local errors=0
    local line_num=0

    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))

        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        IFS=',' read -r mac ip component_id nid bmc_ip bmc_user bmc_pass <<< "$line"

        # Trim whitespace
        mac="${mac// /}"
        ip="${ip// /}"
        component_id="${component_id// /}"
        nid="${nid// /}"
        bmc_ip="${bmc_ip// /}"
        bmc_user="${bmc_user// /}"
        bmc_pass="${bmc_pass// /}"

        if [ -z "$mac" ] || [ -z "$ip" ] || [ -z "$component_id" ] || [ -z "$nid" ] \
            || [ -z "$bmc_ip" ] || [ -z "$bmc_user" ] || [ -z "$bmc_pass" ]; then
            error "Line $line_num: Missing field(s). Expected: mac,ip,component_id,nid,bmc_ip,bmc_user,bmc_pass"
            errors=$((errors + 1))
            continue
        fi

        if ! validate_mac "$mac" "Line $line_num MAC"; then
            errors=$((errors + 1))
        fi

        if ! validate_ip "$ip" "Line $line_num IP"; then
            errors=$((errors + 1))
        fi

        if ! validate_positive_int "$nid" "Line $line_num NID"; then
            errors=$((errors + 1))
        fi

        if ! validate_ip "$bmc_ip" "Line $line_num BMC IP"; then
            errors=$((errors + 1))
        fi
    done < "$file"

    if [ "$errors" -gt 0 ]; then
        error "Found $errors error(s) in nodes file '$file'."
        return 1
    fi

    return 0
}

# --- Utilities ---

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

relax_permissions() {
    local target
    for target in "$@"; do
        if [ -e "$target" ]; then
            sudo chmod -R a+rwX "$target"
        fi
    done
}

restore_fs_protected_regular_if_managed() {
    if $IS_MACOS; then
        return 0
    fi

    if [ ! -f "$FS_PROTECTED_REGULAR_STATE_FILE" ]; then
        echo "fs.protected_regular was not managed by this deployment. Skipping restore."
        return 0
    fi

    local previous_value
    previous_value="$(cat "$FS_PROTECTED_REGULAR_STATE_FILE" 2>/dev/null || true)"
    if ! [[ "$previous_value" =~ ^[0-9]+$ ]]; then
        warn "Invalid fs.protected_regular state file content in $FS_PROTECTED_REGULAR_STATE_FILE; removing marker."
        rm -f "$FS_PROTECTED_REGULAR_STATE_FILE"
        return 0
    fi

    local current_value
    current_value="$(sysctl -n fs.protected_regular 2>/dev/null || true)"
    if [ -z "$current_value" ]; then
        warn "Could not read fs.protected_regular during teardown. Leaving marker for manual cleanup."
        return 0
    fi

    if [ "$current_value" = "$previous_value" ]; then
        echo "fs.protected_regular already set to $previous_value."
        rm -f "$FS_PROTECTED_REGULAR_STATE_FILE"
        return 0
    fi

    step "Restoring fs.protected_regular to $previous_value (managed by OpenCHAMI)..."
    if sudo sysctl -w "fs.protected_regular=$previous_value" >/dev/null 2>&1; then
        rm -f "$FS_PROTECTED_REGULAR_STATE_FILE"
    else
        warn "Failed to restore fs.protected_regular to $previous_value. Marker retained at $FS_PROTECTED_REGULAR_STATE_FILE."
    fi
}

get_microservice_ref() {
    local service="$1"
    case "$service" in
        smd) echo "${SMD_REF:-$DEFAULT_SMD_REF}" ;;
        bss) echo "${BSS_REF:-$DEFAULT_BSS_REF}" ;;
        pcs) echo "${PCS_REF:-$DEFAULT_PCS_REF}" ;;
        *)
            error "Unknown microservice '$service' for ref resolution."
            return 1
            ;;
    esac
}

get_microservice_repo_uri() {
    local service="$1"
    case "$service" in
        smd) echo "${SMD_REPO_URI:-$DEFAULT_SMD_REPO_URI}" ;;
        bss) echo "${BSS_REPO_URI:-$DEFAULT_BSS_REPO_URI}" ;;
        pcs) echo "${PCS_REPO_URI:-$DEFAULT_PCS_REPO_URI}" ;;
        *)
            error "Unknown microservice '$service' for repo URI resolution."
            return 1
            ;;
    esac
}

resolve_smd_service_ip() {
    local host_ip="$1"
    local orchestrator="${ORCHESTRATOR:-minikube}"

    if [ "$orchestrator" == "quadlets" ] || [ "$orchestrator" == "docker-compose" ]; then
        echo "$host_ip"
        return 0
    fi

    minikube kubectl -- get svc ochami-smd -n ochami -o jsonpath='{.spec.clusterIP}'
}

require_command() {
    local cmd="$1"
    local msg="${2:-$cmd is required but not installed. Aborting.}"
    if ! command_exists "$cmd"; then
        error "$msg"
        exit 1
    fi
}

generate_secret() {
    if command_exists openssl; then
        openssl rand -hex 24
        return 0
    fi
    if command_exists python3; then
        python3 -c 'import secrets; print(secrets.token_hex(24))'
        return 0
    fi
    if [ -r /dev/urandom ]; then
        od -An -N24 -tx1 /dev/urandom | tr -d ' \n'
        return 0
    fi
    return 1
}

generate_secret_if_unset() {
    local var_name="$1"
    local current_value="${!var_name:-}"
    if [ -n "$current_value" ]; then
        return 0
    fi

    local generated
    generated="$(generate_secret)" || {
        error "Could not generate a secret for $var_name. Set it explicitly in the environment."
        return 1
    }
    if [ -z "$generated" ]; then
        error "Generated empty secret for $var_name. Set it explicitly in the environment."
        return 1
    fi

    printf -v "$var_name" '%s' "$generated"
    export "$var_name"
}

ensure_generated_secrets() {
    local secrets_file="${OPENCHAMI_SECRETS_FILE:-$PROJECT_ROOT/.openchami-secrets.env}"
    local override_postgres_password="${POSTGRES_PASSWORD:-}"
    local override_smd_db_password="${SMD_DB_PASSWORD:-}"
    local override_bss_db_password="${BSS_DB_PASSWORD:-}"
    local override_kea_db_password="${KEA_DB_PASSWORD:-}"
    local override_pcs_db_password="${PCS_DB_PASSWORD:-}"
    local override_stork_db_password="${STORK_DB_PASSWORD:-}"
    local override_hydra_db_password="${HYDRA_DB_PASSWORD:-}"

    if [ -f "$secrets_file" ]; then
        # shellcheck disable=SC1090
        source "$secrets_file"
    fi

    [ -n "$override_postgres_password" ] && POSTGRES_PASSWORD="$override_postgres_password"
    [ -n "$override_smd_db_password" ] && SMD_DB_PASSWORD="$override_smd_db_password"
    [ -n "$override_bss_db_password" ] && BSS_DB_PASSWORD="$override_bss_db_password"
    [ -n "$override_kea_db_password" ] && KEA_DB_PASSWORD="$override_kea_db_password"
    [ -n "$override_pcs_db_password" ] && PCS_DB_PASSWORD="$override_pcs_db_password"
    [ -n "$override_stork_db_password" ] && STORK_DB_PASSWORD="$override_stork_db_password"
    [ -n "$override_hydra_db_password" ] && HYDRA_DB_PASSWORD="$override_hydra_db_password"

    generate_secret_if_unset POSTGRES_PASSWORD || return 1
    generate_secret_if_unset SMD_DB_PASSWORD || return 1
    generate_secret_if_unset BSS_DB_PASSWORD || return 1
    generate_secret_if_unset KEA_DB_PASSWORD || return 1
    generate_secret_if_unset PCS_DB_PASSWORD || return 1
    generate_secret_if_unset STORK_DB_PASSWORD || return 1
    generate_secret_if_unset HYDRA_DB_PASSWORD || return 1

    local old_umask
    old_umask="$(umask)"
    umask 077
    cat > "$secrets_file" <<EOF
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
SMD_DB_PASSWORD=$SMD_DB_PASSWORD
BSS_DB_PASSWORD=$BSS_DB_PASSWORD
KEA_DB_PASSWORD=$KEA_DB_PASSWORD
PCS_DB_PASSWORD=$PCS_DB_PASSWORD
STORK_DB_PASSWORD=$STORK_DB_PASSWORD
HYDRA_DB_PASSWORD=$HYDRA_DB_PASSWORD
EOF
    umask "$old_umask"
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
    local container_runtime="${container_tool##* }"

    run_container_tool() {
        # container_tool may be a prefixed command such as "sudo podman".
        # shellcheck disable=SC2086
        $container_tool "$@"
    }

    export CONTAINER_TOOL="$container_tool"
    export ORCHESTRATOR="$orchestrator"

    # Helper functions
    image_exists_in_minikube() {
        minikube image ls | grep -q "$1"
    }

    build_local_image_for_tool() {
        local image="$1"
        local context="$2"
        shift 2
        local build_args=("$@")

        if [ "$container_runtime" != "docker" ]; then
            run_container_tool build "${build_args[@]}" -t "$image" "$context"
            return 0
        fi

        docker build "${build_args[@]}" -t "$image" "$context"
        if docker image inspect "$image" >/dev/null 2>&1; then
            return 0
        fi

        echo "docker build did not load '$image' locally; retrying with buildx --load."
        docker buildx build --load "${build_args[@]}" -t "$image" "$context"
    }

    local IMAGE_CHECK_CMD
    if [ "$orchestrator" == "quadlets" ]; then
        IMAGE_CHECK_CMD="run_container_tool image exists"
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
    elif [ "$orchestrator" == "quadlets" ]; then
        if ! run_container_tool image exists "$IMAGE_HTTP" || ! run_container_tool image exists "$IMAGE_EMULATOR"; then
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
    elif [ "$orchestrator" == "quadlets" ]; then
        if ! run_container_tool image exists "$IMAGE_TFTP"; then
            need_tftp=true
        fi
    else
        if ! image_exists_in_minikube "$IMAGE_TFTP"; then
            need_tftp=true
        fi
    fi

    if [ "$need_tftp" = true ]; then
        echo "Building tftp server..."
        build_local_image_for_tool "$IMAGE_TFTP" "$PROJECT_ROOT/ochami-helm/tftp/" --build-arg BASE_IMAGE="$BASE_IMAGE_TFTP"
        if [ "$orchestrator" == "minikube" ]; then
            echo "Loading $IMAGE_TFTP into Minikube..."
            if [ "$container_runtime" == "docker" ]; then
                docker save "$IMAGE_TFTP" | minikube image load -
            else
                minikube image load "$IMAGE_TFTP"
            fi
        fi
    else
        echo "Image $IMAGE_TFTP found. Skipping build."
    fi

    # Build Stork Agent
    local need_stork_agent=false
    if [ "$force_rebuild" = true ]; then
        need_stork_agent=true
    elif [ "$orchestrator" == "docker-compose" ]; then
        if ! docker image inspect "$IMAGE_STORK_AGENT" >/dev/null 2>&1; then
            need_stork_agent=true
        fi
    elif [ "$orchestrator" == "quadlets" ]; then
        if ! run_container_tool image exists "$IMAGE_STORK_AGENT"; then
            need_stork_agent=true
        fi
    else
        if ! image_exists_in_minikube "$IMAGE_STORK_AGENT"; then
            need_stork_agent=true
        fi
    fi

    if [ "$need_stork_agent" = true ]; then
        echo "Building stork-agent..."
        build_local_image_for_tool "$IMAGE_STORK_AGENT" "$PROJECT_ROOT/ochami-helm/stork-agent/" --build-arg BASE_IMAGE="$BASE_IMAGE_STORK_AGENT"
        if [ "$orchestrator" == "minikube" ]; then
            echo "Loading $IMAGE_STORK_AGENT into Minikube..."
            if [ "$container_runtime" == "docker" ]; then
                docker save "$IMAGE_STORK_AGENT" | minikube image load -
            else
                minikube image load "$IMAGE_STORK_AGENT"
            fi
        fi
    else
        echo "Image $IMAGE_STORK_AGENT found. Skipping build."
    fi

    # Build Kea sidecar
    local need_kea_sidecar=false
    if [ "$force_rebuild" = true ]; then
        need_kea_sidecar=true
    elif [ "$orchestrator" == "docker-compose" ]; then
        if ! docker image inspect "$IMAGE_KEA_SIDECAR" >/dev/null 2>&1; then
            need_kea_sidecar=true
        fi
    elif [ "$orchestrator" == "quadlets" ]; then
        if ! run_container_tool image exists "$IMAGE_KEA_SIDECAR"; then
            need_kea_sidecar=true
        fi
    else
        if ! image_exists_in_minikube "$IMAGE_KEA_SIDECAR"; then
            need_kea_sidecar=true
        fi
    fi

    if [ "$need_kea_sidecar" = true ]; then
        echo "Building kea-sidecar..."
        build_local_image_for_tool "$IMAGE_KEA_SIDECAR" "$PROJECT_ROOT/ochami-helm/kea-sidecar/" --build-arg BASE_IMAGE="$BASE_IMAGE_KEA_SIDECAR"
        if [ "$orchestrator" == "minikube" ]; then
            echo "Loading $IMAGE_KEA_SIDECAR into Minikube..."
            if [ "$container_runtime" == "docker" ]; then
                docker save "$IMAGE_KEA_SIDECAR" | minikube image load -
            else
                minikube image load "$IMAGE_KEA_SIDECAR"
            fi
        fi
    else
        echo "Image $IMAGE_KEA_SIDECAR found. Skipping build."
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
        elif [ "$orchestrator" == "quadlets" ]; then
            if ! run_container_tool image exists "$img"; then
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
                local SERVICE_REF
                local SERVICE_REPO_URI
                SERVICE_REF="$(get_microservice_ref "$NAME")" || exit 1
                SERVICE_REPO_URI="$(get_microservice_repo_uri "$NAME")" || exit 1
                echo "Using git ref '$SERVICE_REF' and repo URI '$SERVICE_REPO_URI' for microservice '$NAME' (image tag: '$TAG')."
                $FUNC "$SERVICE_REF" "$TAG" "$SERVICE_REPO_URI"

                if [[ "$NAME" == "coresmd" ]]; then
                    if ! run_container_tool image inspect "$img" >/dev/null 2>&1; then
                        if run_container_tool image inspect "localhost/coresmd:local-build" >/dev/null 2>&1; then
                            echo "Retagging coresmd:local-build to $TAG..."
                            run_container_tool tag "localhost/coresmd:local-build" "$img"
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

    # NOTE: This function is called via command substitution (stdout is captured).
    # All informational messages MUST go to stderr (>&2).
    # Only the final interface name should go to stdout.

    # Disable dnsmasq from libvirt (if present) to avoid conflicts on port 67
    if command_exists virsh; then
        step "Checking for conflicting libvirt dnsmasq..." >&2
        if virsh net-info default >/dev/null 2>&1; then
            if virsh net-info default | grep "Active: *yes" >/dev/null 2>&1; then
                echo "Stopping libvirt default network..." >&2
                sudo virsh net-destroy default >&2 || echo "Failed to stop default network, maybe not running." >&2
            fi
            if virsh net-list --autostart | grep "default" >/dev/null 2>&1; then
                echo "Disabling autostart for libvirt default network..." >&2
                sudo virsh net-autostart --disable default >&2 || echo "Failed to disable autostart for default network." >&2
            fi
        else
            echo "Libvirt default network not found or not active. No action needed." >&2
        fi
    else
        echo "virsh command not found. Skipping libvirt dnsmasq check." >&2
    fi

    # Auto-adjust interface if using defaults and phy-iface is provided
    if [ "$pxe_interface" == "virbr-pxe" ] && [ -n "$phy_iface" ]; then
        step "Hardware Mode: Using physical interface $phy_iface directly (replacing virbr-pxe)." >&2
        echo "$phy_iface"
        return 0
    fi

    if [ "$pxe_interface" == "virbr-pxe" ]; then
        warn "Mode is hardware but interface is default 'virbr-pxe'." >&2
        echo "Since libvirt network creation is skipped in hardware mode, 'virbr-pxe' will likely not exist." >&2
        echo "Ensure you provide a valid interface with --interface or that 'virbr-pxe' is created manually." >&2
    fi

    echo "$pxe_interface"
}

configure_libvirt_network() {
    local pxe_interface="$1"

    if $IS_MACOS; then
        echo "macOS: Skipping libvirt network configuration (not available on macOS)."
        return 0
    fi

    if [ "$pxe_interface" == "virbr-pxe" ]; then
        if ! virsh net-info pxe-net >/dev/null 2>&1; then
            echo "Defining pxe-net network..."
            virsh net-define <(cat <<EOF
<network>
  <name>pxe-net</name>
  <uuid>c8f874f7-dd7a-465c-862a-ec30f41ac4bb</uuid>
  <bridge name='virbr-pxe' stp='on' delay='0'/>
  <mac address='52:54:00:d8:3f:37'/>
  <dns enable='no'/>
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
    if $IS_MACOS; then
        echo "macOS: Docker Desktop manages its own networking. Skipping firewall configuration."
        return 0
    fi
    if systemctl is-active --quiet firewalld; then
        echo "Configuring firewall for $pxe_interface..."
        sudo firewall-cmd --zone=trusted --add-interface="$pxe_interface" --permanent
        sudo firewall-cmd --reload
    fi
}

check_dhcp_port_conflict() {
    local pxe_interface="$1"
    local conflict_policy="${2:-${DHCP_CONFLICT_POLICY:-$DEFAULT_DHCP_CONFLICT_POLICY}}"
    step "Checking for DHCP port conflicts on $pxe_interface (policy: $conflict_policy)..."

    if [[ "$conflict_policy" != "fail" && "$conflict_policy" != "auto-kill" ]]; then
        error "Invalid DHCP conflict policy '$conflict_policy'. Use 'fail' or 'auto-kill'."
        return 1
    fi

    local conflict pids
    if $IS_MACOS; then
        conflict=$(sudo lsof -i UDP:67 -P -n 2>/dev/null | grep -v "^COMMAND" || true)
        if [ -n "$conflict" ]; then
            pids=$(echo "$conflict" | awk '{print $2}' | sort -u || true)
        fi
    else
        # ss -ulnp with UDP-only filter uses "State" as header (no Netid column)
        conflict=$(sudo ss -ulnp 'sport = :67' 2>/dev/null | grep -v "^State" || true)
        if [ -n "$conflict" ]; then
            # Extract PID(s) from ss output (format: pid=NNNN)
            pids=$(echo "$conflict" | grep -oP 'pid=\K[0-9]+' | sort -u || true)
            if [ -z "$pids" ]; then
                # Fall back to fuser if ss doesn't report process info (requires root)
                pids=$(sudo fuser 67/udp 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)
            fi
        fi
    fi

    if [ -z "${conflict:-}" ]; then
        echo "No DHCP port conflict detected."
        return 0
    fi

    warn "Another process is already bound to UDP port 67 (DHCP):"
    echo "$conflict"

    if [ -z "${pids:-}" ]; then
        warn "Could not determine conflicting PID(s). Please free port 67/UDP manually before deploying."
        return 1
    fi

    if [ "$conflict_policy" = "fail" ]; then
        warn "Port 67/UDP is in use. Deployment failed by policy (--fail-on-conflict)."
        warn "Re-run with --auto-kill to terminate conflicting process(es) automatically."
        return 1
    fi

    for pid in $pids; do
        local proc_name
        proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        echo "Killing conflicting process: $proc_name (PID $pid)"
        sudo kill "$pid"
    done

    sleep 1
    echo "DHCP port conflict resolved by auto-kill policy."
    return 0
}

# --- BSS Registration ---

register_bss_defaults() {
    local bss_ip="$1"
    local host_ip="$2"
    local extra_params="${3:-}"
    local artifacts_url="http://${host_ip}:${HTTP_PORT}/artifacts"
    local params="console=ttyS0 ip=dhcp rd.neednet=1 root=live:${artifacts_url}/rootfs.squashfs"
    if [ -n "$extra_params" ]; then
        params="$params $extra_params"
    fi

    echo "BSS Service IP: $bss_ip"
    echo "Registering 'Default' boot parameters in BSS..."

    for i in $(seq 1 30); do
        if curl -s -f -X PUT "http://${bss_ip}:${BSS_PORT}/boot/v1/bootparameters" \
          -H "Content-Type: application/json" \
          -d "{
            \"hosts\": [\"Default\"],
            \"kernel\": \"${artifacts_url}/vmlinuz-lts\",
            \"initrd\": \"${artifacts_url}/initramfs-lts\",
            \"params\": \"${params}\"
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

# --- Hardware Node Registration ---

resolve_service_endpoints() {
    local host_ip="$1"
    local orchestrator="${2:-${ORCHESTRATOR:-minikube}}"
    local smd_ip bss_ip

    if [ "$orchestrator" == "quadlets" ] || [ "$orchestrator" == "docker-compose" ]; then
        smd_ip="$host_ip"
        bss_ip="$host_ip"
    else
        smd_ip=$(minikube kubectl -- get svc ochami-smd -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
        bss_ip=$(minikube kubectl -- get svc ochami-bss -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    fi

    if [ -z "$smd_ip" ] || [ -z "$bss_ip" ]; then
        error "Could not resolve SMD or BSS service IP."
        return 1
    fi

    printf '%s %s\n' "$smd_ip" "$bss_ip"
}

apply_bss_nodes_workaround() {
    local mac="$1"
    local nid="$2"
    local component_id="$3"
    local orchestrator="$4"

    local update_cmd="psql -U ${BSS_DB_USER} -d ${BSS_DB_NAME} -c \"UPDATE nodes SET boot_mac = '${mac}', nid = ${nid} WHERE xname = '${component_id}';\""

    if [ "$orchestrator" == "docker-compose" ]; then
        local pg_container
        pg_container=$(docker ps --format "{{.Names}}" | grep postgres | head -n 1)
        if [ -n "$pg_container" ]; then
            if docker exec "$pg_container" bash -c "$update_cmd" >/dev/null 2>&1; then
                echo "  -> Database updated (Docker Compose)"
            else
                warn "  Failed to update boot_mac in database (Docker Compose)"
            fi
        else
            warn "  Postgres container not found (Docker Compose)"
        fi
    elif [ "$orchestrator" == "quadlets" ]; then
        local pg_container
        pg_container=$(sudo podman ps --format "{{.Names}}" | grep postgres | head -n 1)
        if [ -n "$pg_container" ]; then
            if sudo podman exec "$pg_container" bash -c "$update_cmd" >/dev/null 2>&1; then
                echo "  -> Database updated (Quadlets)"
            else
                warn "  Failed to update boot_mac in database (Quadlets)"
            fi
        else
            warn "  Postgres container not found (Quadlets)"
        fi
    else
        if minikube kubectl -- exec -n ochami ochami-postgres -- bash -c "$update_cmd" >/dev/null 2>&1; then
            echo "  -> Database updated (Minikube)"
        else
            warn "  Failed to update boot_mac in database (Minikube)"
        fi
    fi
}

register_hardware_node_with_endpoints() {
    local mac="$1"
    local ip="$2"
    local component_id="$3"
    local nid="$4"
    local bmc_ip="$5"
    local bmc_user="$6"
    local bmc_pass="$7"
    local smd_ip="$8"
    local bss_ip="$9"
    local host_ip="${10}"
    local orchestrator="${11:-${ORCHESTRATOR:-minikube}}"
    local context="${12:-$component_id}"
    local artifacts_url="${ARTIFACTS_URL:-http://${host_ip}:${HTTP_PORT}/artifacts}"
    local bmc_xname="${component_id%n[0-9]*}"
    local http_code

    echo ""
    step "Registering ${context}: $component_id (MAC=$mac, IP=$ip, NID=$nid, BMC=$bmc_ip)"

    # 1. Register Component in SMD
    echo "  Creating Node Component in SMD..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://${smd_ip}:${SMD_PORT}/hsm/v2/State/Components" \
        -H "Content-Type: application/json" \
        -d "{
            \"Components\": [{
                \"ID\": \"${component_id}\",
                \"Type\": \"Node\",
                \"State\": \"On\",
                \"Flag\": \"OK\",
                \"Role\": \"Compute\",
                \"NID\": ${nid},
                \"NetType\": \"Sling\"
            }]
        }")
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "  -> Component created ($http_code)"
    else
        echo "  -> Component registration returned $http_code (may already exist)"
    fi

    # 2. Register EthernetInterface in SMD
    echo "  Registering EthernetInterface in SMD..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://${smd_ip}:${SMD_PORT}/hsm/v2/Inventory/EthernetInterfaces" \
        -H "Content-Type: application/json" \
        -d "{
            \"Description\": \"Hardware Node NIC\",
            \"MACAddress\": \"${mac}\",
            \"IPAddresses\": [{\"IPAddress\": \"${ip}\"}],
            \"ComponentID\": \"${component_id}\"
        }")
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "  -> EthernetInterface created ($http_code)"
    else
        echo "  -> EthernetInterface registration returned $http_code (may already exist)"
    fi

    # 3. Register RedfishEndpoint in SMD
    echo "  Registering RedfishEndpoint for BMC ($bmc_xname) at $bmc_ip..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://${smd_ip}:${SMD_PORT}/hsm/v2/Inventory/RedfishEndpoints" \
        -H "Content-Type: application/json" \
        -d "{
            \"ID\": \"${bmc_xname}\",
            \"RediscoverOnUpdate\": true,
            \"Hostname\": \"${bmc_ip}\",
            \"User\": \"${bmc_user}\",
            \"Password\": \"${bmc_pass}\"
        }")
    if [ "$http_code" -eq 409 ]; then
        echo "  -> Endpoint exists (409). Updating via PUT to trigger rediscovery..."
        curl -s -X PUT "http://${smd_ip}:${SMD_PORT}/hsm/v2/Inventory/RedfishEndpoints/${bmc_xname}" \
            -H "Content-Type: application/json" \
            -d "{
                \"ID\": \"${bmc_xname}\",
                \"RediscoverOnUpdate\": true,
                \"Hostname\": \"${bmc_ip}\",
                \"User\": \"${bmc_user}\",
                \"Password\": \"${bmc_pass}\"
            }" > /dev/null
    elif [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "  -> RedfishEndpoint created ($http_code)"
    else
        echo "  -> RedfishEndpoint registration returned $http_code"
    fi

    # 4. Trigger Redfish Discovery
    echo "  Triggering SMD Redfish discovery for ${bmc_xname}..."
    curl -s -X POST "http://${smd_ip}:${SMD_PORT}/hsm/v2/Inventory/Discover" \
        -H "Content-Type: application/json" \
        -d "{\"xnames\":[\"${bmc_xname}\"]}" > /dev/null

    # 5. Register per-node boot params in BSS
    echo "  Registering boot parameters in BSS..."
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        "http://${bss_ip}:${BSS_PORT}/boot/v1/bootparameters" \
        -H "Content-Type: application/json" \
        -d "{
            \"hosts\": [\"${component_id}\"],
            \"macs\": [\"${mac}\"],
            \"kernel\": \"${artifacts_url}/vmlinuz-lts\",
            \"initrd\": \"${artifacts_url}/initramfs-lts\",
            \"params\": \"console=ttyS0 ip=dhcp rd.neednet=1 root=live:${artifacts_url}/rootfs.squashfs\"
        }")
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "  -> Boot parameters registered ($http_code)"
    else
        echo "  -> Boot parameters registration returned $http_code"
    fi

    # 6. Apply boot_mac + nid database workaround
    # BSS API doesn't properly save boot_mac or nid in the nodes table.
    # Without boot_mac, BSS can't look up boot params by MAC.
    # Without nid, BSS treats the node as unknown/disabled.
    echo "  Applying BSS nodes table workaround (boot_mac + nid)..."
    apply_bss_nodes_workaround "$mac" "$nid" "$component_id" "$orchestrator"
}

register_hardware_nodes_from_file() {
    local file="$1"
    local host_ip="$2"
    local orchestrator="${ORCHESTRATOR:-minikube}"
    local smd_ip bss_ip
    read -r smd_ip bss_ip < <(resolve_service_endpoints "$host_ip" "$orchestrator") || return 1

    echo "SMD endpoint: http://${smd_ip}:${SMD_PORT}"
    echo "BSS endpoint: http://${bss_ip}:${BSS_PORT}"

    local node_count=0
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        IFS=',' read -r mac ip component_id nid bmc_ip bmc_user bmc_pass <<< "$line"
        mac="${mac// /}"
        ip="${ip// /}"
        component_id="${component_id// /}"
        nid="${nid// /}"
        bmc_ip="${bmc_ip// /}"
        bmc_user="${bmc_user// /}"
        bmc_pass="${bmc_pass// /}"

        node_count=$((node_count + 1))
        register_hardware_node_with_endpoints \
            "$mac" "$ip" "$component_id" "$nid" "$bmc_ip" "$bmc_user" "$bmc_pass" \
            "$smd_ip" "$bss_ip" "$host_ip" "$orchestrator" "node $node_count"
    done < "$file"

    echo ""
    info "Registered $node_count hardware node(s) from $file."
}

run_magellan_discovery() {
    local host_ip="$1"
    local orchestrator="${ORCHESTRATOR:-minikube}"
    local smd_ip

    require_command magellan "magellan is required for --discovery-method magellan."

    smd_ip=$(resolve_smd_service_ip "$host_ip")
    if [ -z "$smd_ip" ]; then
        error "Could not resolve SMD service IP for Magellan discovery."
        return 1
    fi

    local cache="${MAGELLAN_CACHE:-/tmp/$USER/magellan/assets.db}"
    mkdir -p "$(dirname "$cache")"

    local scan_cmd=(magellan scan --cache "$cache")
    local has_scan_target=false

    if [ -n "${MAGELLAN_SUBNETS:-}" ]; then
        local subnet
        IFS=',' read -r -a _magellan_subnets <<< "$MAGELLAN_SUBNETS"
        for subnet in "${_magellan_subnets[@]}"; do
            subnet="${subnet// /}"
            [ -z "$subnet" ] && continue
            scan_cmd+=(--subnet "$subnet")
            has_scan_target=true
        done
    fi

    local -a scan_hosts=()
    if [ -n "${MAGELLAN_HOSTS:-}" ]; then
        local host
        IFS=',' read -r -a _magellan_hosts <<< "$MAGELLAN_HOSTS"
        for host in "${_magellan_hosts[@]}"; do
            host="${host// /}"
            [ -z "$host" ] && continue
            scan_hosts+=("$host")
            has_scan_target=true
        done
    fi

    if ! $has_scan_target; then
        error "Magellan discovery requires at least one scan target via --magellan-subnets or --magellan-hosts."
        return 1
    fi

    if [ -n "${MAGELLAN_SUBNET_MASK:-}" ]; then
        scan_cmd+=(--subnet-mask "$MAGELLAN_SUBNET_MASK")
    fi
    if [ "${MAGELLAN_INSECURE:-false}" = "true" ]; then
        scan_cmd+=(--insecure)
    fi
    if [ "${#scan_hosts[@]}" -gt 0 ]; then
        scan_cmd+=("${scan_hosts[@]}")
    fi

    local collect_cmd=(magellan collect --cache "$cache" --show --format json)
    if [ -n "${MAGELLAN_BMC_USER:-}" ]; then
        collect_cmd+=(--username "$MAGELLAN_BMC_USER")
    fi
    if [ -n "${MAGELLAN_BMC_PASS:-}" ]; then
        collect_cmd+=(--password "$MAGELLAN_BMC_PASS")
    fi
    if [ -n "${MAGELLAN_BMC_ID_MAP:-}" ]; then
        collect_cmd+=(--bmc-id-map "$MAGELLAN_BMC_ID_MAP")
    fi
    if [ "${MAGELLAN_INSECURE:-false}" = "true" ]; then
        collect_cmd+=(--insecure)
    fi
    local collect_output
    collect_output="$(mktemp --suffix=.json)"
    local send_cmd=(magellan send -d "@${collect_output}" "http://${smd_ip}:${SMD_PORT}")

    step "Running Magellan scan (orchestrator=$orchestrator)..."
    "${scan_cmd[@]}"
    step "Collecting inventory via Magellan..."
    "${collect_cmd[@]}" > "$collect_output"

    if [ ! -s "$collect_output" ] || [ "$(tr -d '[:space:]' < "$collect_output")" = "[]" ]; then
        warn "Magellan discovered no assets to send to SMD."
        rm -f "$collect_output"
        return 0
    fi

    step "Sending Magellan-discovered inventory to SMD..."
    "${send_cmd[@]}"
    rm -f "$collect_output"
    info "Magellan discovery completed and inventory sent to SMD."
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

create_vms_only() {
    local num_vms="$1"

    for i in $(seq 0 $((num_vms - 1))); do
        local vm_name="virtual-compute-node-$i"
        echo "Creating $vm_name..."
        sudo "$PROJECT_ROOT/scripts/create_vm.sh" --name "$vm_name"
    done
}

# --- CLI Helpers ---

parse_common_deploy_args() {
    FORCE_REBUILD=false
    DHCP_START=""
    DHCP_END=""
    DHCP_NETMASK=""
    DHCP_CONFLICT_POLICY="$DEFAULT_DHCP_CONFLICT_POLICY"
    SET_FS_PROTECTED_REGULAR="$DEFAULT_SET_FS_PROTECTED_REGULAR"
    PXE_INTERFACE="$DEFAULT_PXE_INTERFACE"
    PXE_IP="$DEFAULT_PXE_IP"
    PXE_CIDR="$DEFAULT_PXE_CIDR"
    PHY_IFACE=""
    MODE="$DEFAULT_MODE"
    NUM_VMS="$DEFAULT_NUM_VMS"
    NODES_FILE=""
    SMD_REF="$DEFAULT_SMD_REF"
    BSS_REF="$DEFAULT_BSS_REF"
    PCS_REF="$DEFAULT_PCS_REF"
    SMD_REPO_URI="$DEFAULT_SMD_REPO_URI"
    BSS_REPO_URI="$DEFAULT_BSS_REPO_URI"
    PCS_REPO_URI="$DEFAULT_PCS_REPO_URI"
    DISCOVERY_METHOD="$DEFAULT_DISCOVERY_METHOD"
    MAGELLAN_SUBNETS=""
    MAGELLAN_HOSTS=""
    MAGELLAN_SUBNET_MASK=""
    MAGELLAN_BMC_USER=""
    MAGELLAN_BMC_PASS=""
    MAGELLAN_BMC_ID_MAP=""
    MAGELLAN_CACHE=""
    MAGELLAN_INSECURE=false

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --rebuild) FORCE_REBUILD=true ;;
            --dhcp-start) DHCP_START="$2"; shift ;;
            --dhcp-end) DHCP_END="$2"; shift ;;
            --dhcp-netmask) DHCP_NETMASK="$2"; shift ;;
            --fail-on-conflict) DHCP_CONFLICT_POLICY="fail" ;;
            --auto-kill) DHCP_CONFLICT_POLICY="auto-kill" ;;
            --set-fs-protected-regular) SET_FS_PROTECTED_REGULAR=true ;;
            --interface) PXE_INTERFACE="$2"; shift ;;
            --ip) PXE_IP="$2"; shift ;;
            --cidr) PXE_CIDR="$2"; shift ;;
            --phy-iface) PHY_IFACE="$2"; shift ;;
            --mode) MODE="$2"; shift ;;
            --vms) NUM_VMS="$2"; shift ;;
            --nodes-file) NODES_FILE="$2"; shift ;;
            --smd-ref) SMD_REF="$2"; shift ;;
            --bss-ref) BSS_REF="$2"; shift ;;
            --pcs-ref) PCS_REF="$2"; shift ;;
            --smd-repo-uri) SMD_REPO_URI="$2"; shift ;;
            --bss-repo-uri) BSS_REPO_URI="$2"; shift ;;
            --pcs-repo-uri) PCS_REPO_URI="$2"; shift ;;
            --discovery-method) DISCOVERY_METHOD="$2"; shift ;;
            --magellan-subnets) MAGELLAN_SUBNETS="$2"; shift ;;
            --magellan-hosts) MAGELLAN_HOSTS="$2"; shift ;;
            --magellan-subnet-mask) MAGELLAN_SUBNET_MASK="$2"; shift ;;
            --magellan-bmc-user) MAGELLAN_BMC_USER="$2"; shift ;;
            --magellan-bmc-pass) MAGELLAN_BMC_PASS="$2"; shift ;;
            --magellan-bmc-id-map) MAGELLAN_BMC_ID_MAP="$2"; shift ;;
            --magellan-cache) MAGELLAN_CACHE="$2"; shift ;;
            --magellan-insecure) MAGELLAN_INSECURE=true ;;
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
    if [[ "$DHCP_CONFLICT_POLICY" != "fail" && "$DHCP_CONFLICT_POLICY" != "auto-kill" ]]; then
        error "DHCP conflict policy must be 'fail' or 'auto-kill'."
        exit 1
    fi
    if [[ "$SET_FS_PROTECTED_REGULAR" != "true" && "$SET_FS_PROTECTED_REGULAR" != "false" ]]; then
        error "fs.protected_regular policy must be 'true' or 'false'."
        exit 1
    fi

    # Validate nodes file
    if [ -n "$NODES_FILE" ]; then
        if [ ! -f "$NODES_FILE" ]; then
            error "Nodes file '$NODES_FILE' does not exist."
            exit 1
        fi
    fi

    if [ -z "$SMD_REF" ] || [ -z "$BSS_REF" ] || [ -z "$PCS_REF" ]; then
        error "Microservice refs must be non-empty. Check --smd-ref, --bss-ref, and --pcs-ref."
        exit 1
    fi
    if [ -z "$SMD_REPO_URI" ] || [ -z "$BSS_REPO_URI" ] || [ -z "$PCS_REPO_URI" ]; then
        error "Microservice repo URIs must be non-empty. Check --smd-repo-uri, --bss-repo-uri, and --pcs-repo-uri."
        exit 1
    fi

    if [[ "$DISCOVERY_METHOD" != "static" && "$DISCOVERY_METHOD" != "magellan" ]]; then
        error "--discovery-method must be 'static' or 'magellan'."
        exit 1
    fi

    if [ "$DISCOVERY_METHOD" == "magellan" ]; then
        if [ -n "$NODES_FILE" ]; then
            error "--nodes-file cannot be combined with --discovery-method magellan."
            exit 1
        fi

        if [ -z "$MAGELLAN_SUBNETS" ] && [ -z "$MAGELLAN_HOSTS" ]; then
            error "Magellan discovery requires --magellan-subnets and/or --magellan-hosts."
            exit 1
        fi

        if { [ -n "$MAGELLAN_BMC_USER" ] && [ -z "$MAGELLAN_BMC_PASS" ]; } || { [ -z "$MAGELLAN_BMC_USER" ] && [ -n "$MAGELLAN_BMC_PASS" ]; }; then
            error "--magellan-bmc-user and --magellan-bmc-pass must be specified together."
            exit 1
        fi
    fi

    if [ -n "$MAGELLAN_SUBNET_MASK" ]; then
        validate_ip "$MAGELLAN_SUBNET_MASK" "--magellan-subnet-mask" || exit 1
    fi
    if [ -n "$MAGELLAN_CACHE" ] && [ -z "${MAGELLAN_CACHE// /}" ]; then
        error "--magellan-cache must be non-empty when set."
        exit 1
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
  --fail-on-conflict     Abort if UDP/67 is already in use (default behavior)
  --auto-kill            Kill conflicting UDP/67 process(es) automatically
  --set-fs-protected-regular
                         Opt in to setting host fs.protected_regular=0 during prerequisite install
  --interface NAME       PXE interface (default: $DEFAULT_PXE_INTERFACE)
  --ip IP                Host IP on PXE interface (default: $DEFAULT_PXE_IP)
  --cidr N               CIDR prefix (default: $DEFAULT_PXE_CIDR)
  --phy-iface NAME       Physical interface to bridge
  --mode MODE            'libvirt' or 'hardware' (default: $DEFAULT_MODE)
  --vms N                Number of VMs to create (default: $DEFAULT_NUM_VMS)
  --nodes-file FILE      CSV file with hardware nodes (mac,ip,component_id,nid,bmc_ip,bmc_user,bmc_pass)
  --smd-ref REF          Git ref to build for SMD image (default: $DEFAULT_SMD_REF)
  --bss-ref REF          Git ref to build for BSS image (default: $DEFAULT_BSS_REF)
  --pcs-ref REF          Git ref to build for PCS image (default: $DEFAULT_PCS_REF)
  --smd-repo-uri URI     Git repository URI for SMD builds (default: $DEFAULT_SMD_REPO_URI)
  --bss-repo-uri URI     Git repository URI for BSS builds (default: $DEFAULT_BSS_REPO_URI)
  --pcs-repo-uri URI     Git repository URI for PCS builds (default: $DEFAULT_PCS_REPO_URI)
  --discovery-method M   Discovery mode: 'static' (CSV registration) or 'magellan' (default: $DEFAULT_DISCOVERY_METHOD)
  --magellan-subnets L   Comma-separated subnets for Magellan scan (e.g. 172.16.0.0/24,10.0.0.0/16)
  --magellan-hosts L     Comma-separated hosts/URIs for Magellan scan
  --magellan-subnet-mask IP
                         Subnet mask used with non-CIDR --magellan-subnets
  --magellan-bmc-user U  BMC username used by Magellan collect
  --magellan-bmc-pass P  BMC password used by Magellan collect
  --magellan-bmc-id-map M
                         BMC ID map for Magellan collect (raw JSON/YAML or @/path/to/map.yaml)
  --magellan-cache PATH  Magellan cache path (default: /tmp/\$USER/magellan/assets.db)
  --magellan-insecure    Skip TLS certificate verification during Magellan scan
  -h, --help             Show help
EOF
}

# --- Teardown Helpers ---

destroy_vms() {
    local vm_name="$1"

    if $IS_MACOS; then
        echo "macOS: VM management via libvirt is not available. Skipping VM removal."
        return 0
    fi

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

    if $IS_MACOS; then
        echo "macOS: Libvirt network management is not available. Skipping PXE network removal."
        return 0
    fi

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
    local host_cidr="${3:-24}"

    if $IS_MACOS; then
        echo "macOS: Docker Desktop manages its own networking. Skipping host networking cleanup."
        return 0
    fi

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
        step "Removing IP $host_ip/$host_cidr from $host_iface..."
        if ! sudo ip addr del "$host_ip/$host_cidr" dev "$host_iface" 2>/dev/null; then
            warn "Could not remove $host_ip/$host_cidr from $host_iface. If a different CIDR was used at deploy time, rerun teardown with --cidr."
        fi
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
    PXE_INTERFACE="$DEFAULT_PXE_INTERFACE"
    PXE_IP="$DEFAULT_PXE_IP"
    PXE_CIDR="$DEFAULT_PXE_CIDR"

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --remove-images) REMOVE_IMAGES=true ;;
            --vm-name) VM_NAME="$2"; shift ;;
            --interface) PXE_INTERFACE="$2"; shift ;;
            --ip) PXE_IP="$2"; shift ;;
            --cidr) PXE_CIDR="$2"; shift ;;
            -y|--yes) SKIP_CONFIRM=true ;;
            -h|--help) return 2 ;;
            *) error "Unknown parameter: $1"; exit 1 ;;
        esac
        shift
    done

    validate_ip "$PXE_IP" "--ip" || return 1
    validate_cidr "$PXE_CIDR" || return 1

    return 0
}

add_common_teardown_args_help() {
    cat <<EOF
Options:
  --remove-images        Also remove container images
  --vm-name NAME         VM name pattern (default: $DEFAULT_VM_NAME)
  --interface NAME      PXE interface to clean up (default: $DEFAULT_PXE_INTERFACE)
  --ip IP               PXE IP to remove from interface (default: $DEFAULT_PXE_IP)
  --cidr N              PXE CIDR prefix for IP cleanup (default: $DEFAULT_PXE_CIDR)
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
