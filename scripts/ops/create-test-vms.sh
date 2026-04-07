#!/usr/bin/env bash
# create-test-vms.sh — Create libvirt test VMs and register them for OpenCHAMI PXE boot.
# Usage: ./create-test-vms.sh --count N [--start-index N] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"

COUNT="${COUNT:-1}"
START_INDEX="${START_INDEX:-0}"
METHOD="${METHOD:-compose}"
NAME_PREFIX="${NAME_PREFIX:-ochami-test-node}"
XNAME_PREFIX="${XNAME_PREFIX:-x1000c0s0b0n}"
LIBVIRT_URI="${LIBVIRT_URI:-}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-2048}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"
VM_DISK_DIR="${VM_DISK_DIR:-/var/lib/libvirt/images/ochami}"
VM_IP_START="${VM_IP_START:-100}"
BOOTSCRIPT_ATTEMPTS="${BOOTSCRIPT_ATTEMPTS:-12}"
BOOTSCRIPT_INTERVAL="${BOOTSCRIPT_INTERVAL:-5}"
BOOTSCRIPT_HOST="${BOOTSCRIPT_HOST:-}"
BOOTSCRIPT_PORT="${BOOTSCRIPT_PORT:-}"
COMPOSE_DIR="${COMPOSE_DIR:-${PROJECT_ROOT}/deploy/compose}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
SECRETS_FILE="${OPENCHAMI_SECRETS:-${PROJECT_ROOT}/.tmp/openchami-secrets.env}"
MANIFEST_FILE="${MANIFEST_FILE:-${PROJECT_ROOT}/.tmp/ochami-test-vms.csv}"
BOOT_ARTIFACTS_PATH="${BOOT_ARTIFACTS_PATH:-}"
KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"
LIBVIRT_BMC_IMAGE="${LIBVIRT_BMC_IMAGE:-localhost/libvirt-bmc:latest}"
EXPLICIT_LIBVIRT_BMC_USER="${LIBVIRT_BMC_USER:-}"
EXPLICIT_LIBVIRT_BMC_PASSWORD="${LIBVIRT_BMC_PASSWORD:-}"
LIBVIRT_BMC_USER="${LIBVIRT_BMC_USER:-}"
LIBVIRT_BMC_PASSWORD="${LIBVIRT_BMC_PASSWORD:-}"
LIBVIRT_BMC_READY_ATTEMPTS="${LIBVIRT_BMC_READY_ATTEMPTS:-30}"
LIBVIRT_BMC_READY_INTERVAL="${LIBVIRT_BMC_READY_INTERVAL:-2}"
LIBVIRT_BMC_LISTEN_PORT="${LIBVIRT_BMC_LISTEN_PORT:-443}"
LIBVIRT_BMC_CONTAINER_PREFIX="${LIBVIRT_BMC_CONTAINER_PREFIX:-ochami-libvirt-bmc}"
LIBVIRT_BMC_SOCKET_PATH="${LIBVIRT_BMC_SOCKET_PATH:-/var/run/libvirt}"
HSM_DISCOVERY_ATTEMPTS="${HSM_DISCOVERY_ATTEMPTS:-30}"
HSM_DISCOVERY_INTERVAL="${HSM_DISCOVERY_INTERVAL:-2}"
PCS_POWER_STATUS_URL="${PCS_POWER_STATUS_URL:-http://localhost/power-control/v1/power-status}"
PCS_READY_ATTEMPTS="${PCS_READY_ATTEMPTS:-20}"
PCS_READY_INTERVAL="${PCS_READY_INTERVAL:-2}"
NETBOOT_CONSOLE_READY_PATTERN="${NETBOOT_CONSOLE_READY_PATTERN:-}"
NETWORK_NAME="${NETWORK_NAME:-}"
NETWORK_BRIDGE="${NETWORK_BRIDGE:-}"
HOST_IP="${HOST_IP:-}"
PXE_CIDR="${PXE_CIDR:-}"
SMD_HOST="${SMD_HOST:-}"
SMD_PORT="${SMD_PORT:-}"

usage() {
  cat <<EOF
Usage: $0 --count N [options]

Options:
  --method METHOD      Runtime backend: compose (default: ${METHOD})
  --count N            Number of test VMs to ensure exist
  --start-index N      Starting index for VM names, xnames, MACs, and reserved IPs
  --name-prefix NAME   Domain name prefix (default: ${NAME_PREFIX})
  --xname-prefix NAME  BMC or legacy node xname prefix (default: ${XNAME_PREFIX})
  --memory-mib N       Memory in MiB per VM (default: ${VM_MEMORY_MIB})
  --vcpus N            vCPUs per VM (default: ${VM_VCPUS})
  --disk-size SIZE     Disk size passed to qemu-img (default: ${VM_DISK_SIZE})
  --disk-dir DIR       Disk image directory (default: ${VM_DISK_DIR})
  --vm-ip-start N      Starting host octet for registered VM IPs (default: ${VM_IP_START})
  --dry-run            Print actions without running them
  -h, --help           Show this help
EOF
}

parse_common_args "$@"

while [ $# -gt 0 ]; do
  case "$1" in
    --method)
      METHOD="${2:-}"
      shift 2
      ;;
    --method=*)
      METHOD="${1#--method=}"
      shift
      ;;
    --count)
      COUNT="${2:-}"
      shift 2
      ;;
    --count=*)
      COUNT="${1#--count=}"
      shift
      ;;
    --start-index)
      START_INDEX="${2:-}"
      shift 2
      ;;
    --start-index=*)
      START_INDEX="${1#--start-index=}"
      shift
      ;;
    --name-prefix)
      NAME_PREFIX="${2:-}"
      shift 2
      ;;
    --name-prefix=*)
      NAME_PREFIX="${1#--name-prefix=}"
      shift
      ;;
    --xname-prefix)
      XNAME_PREFIX="${2:-}"
      shift 2
      ;;
    --xname-prefix=*)
      XNAME_PREFIX="${1#--xname-prefix=}"
      shift
      ;;
    --memory-mib)
      VM_MEMORY_MIB="${2:-}"
      shift 2
      ;;
    --memory-mib=*)
      VM_MEMORY_MIB="${1#--memory-mib=}"
      shift
      ;;
    --vcpus)
      VM_VCPUS="${2:-}"
      shift 2
      ;;
    --vcpus=*)
      VM_VCPUS="${1#--vcpus=}"
      shift
      ;;
    --disk-size)
      VM_DISK_SIZE="${2:-}"
      shift 2
      ;;
    --disk-size=*)
      VM_DISK_SIZE="${1#--disk-size=}"
      shift
      ;;
    --disk-dir)
      VM_DISK_DIR="${2:-}"
      shift 2
      ;;
    --disk-dir=*)
      VM_DISK_DIR="${1#--disk-dir=}"
      shift
      ;;
    --vm-ip-start)
      VM_IP_START="${2:-}"
      shift 2
      ;;
    --vm-ip-start=*)
      VM_IP_START="${1#--vm-ip-start=}"
      shift
      ;;
    --dry-run)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

case "$METHOD" in
  compose|docker-compose)
    METHOD="compose"
    LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
    NETWORK_NAME="${NETWORK_NAME:-ochami-pxe-net}"
    NETWORK_BRIDGE="${NETWORK_BRIDGE:-virbr-ochami}"
    HOST_IP="${HOST_IP:-192.168.100.1}"
    PXE_CIDR="${PXE_CIDR:-24}"
    BOOTSCRIPT_HOST="${BOOTSCRIPT_HOST:-localhost}"
    BOOTSCRIPT_PORT="${BOOTSCRIPT_PORT:-80}"
    SMD_HOST="${SMD_HOST:-localhost}"
    SMD_PORT="${SMD_PORT:-27779}"
    ;;
  *)
    log_error "unknown method: $METHOD"
    usage
    exit 1
    ;;
esac

require_positive_int() {
  local value="$1"
  local name="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 0 ]; then
    log_error "$name must be a non-negative integer (got: $value)"
    exit 1
  fi
}

require_positive_int "$COUNT" "count"
require_positive_int "$START_INDEX" "start-index"
require_positive_int "$VM_MEMORY_MIB" "memory-mib"
require_positive_int "$VM_VCPUS" "vcpus"
require_positive_int "$VM_IP_START" "vm-ip-start"
require_positive_int "$HSM_DISCOVERY_ATTEMPTS" "hsm-discovery-attempts"
require_positive_int "$HSM_DISCOVERY_INTERVAL" "hsm-discovery-interval"
require_positive_int "$PCS_READY_ATTEMPTS" "pcs-ready-attempts"
require_positive_int "$PCS_READY_INTERVAL" "pcs-ready-interval"

if [ "$COUNT" -eq 0 ]; then
  log_info "no VMs requested; nothing to do"
  exit 0
fi

DRY_RUN_FLAG=""
if [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_FLAG="--dry-run"
fi

require_command jq "JSON processing"
require_command virsh "libvirt management"
require_command virt-install "libvirt VM creation"
require_command qemu-img "disk image creation"

XNAME_BMC_PREFIX=""
XNAME_BMC_INDEX_BASE="0"

init_xname_layout() {
  if [[ "$XNAME_PREFIX" =~ ^(.*b)([0-9]+)n$ ]]; then
    XNAME_BMC_PREFIX="${BASH_REMATCH[1]}"
    XNAME_BMC_INDEX_BASE="${BASH_REMATCH[2]}"
    return 0
  fi

  if [[ "$XNAME_PREFIX" =~ ^(.*b)([0-9]+)$ ]]; then
    XNAME_BMC_PREFIX="${BASH_REMATCH[1]}"
    XNAME_BMC_INDEX_BASE="${BASH_REMATCH[2]}"
    return 0
  fi

  if [[ "$XNAME_PREFIX" =~ ^.*b$ ]]; then
    XNAME_BMC_PREFIX="$XNAME_PREFIX"
    XNAME_BMC_INDEX_BASE="0"
    return 0
  fi

  log_error "xname-prefix must identify a BMC lineage like x1000c0s0b or x1000c0s0b0n (got: $XNAME_PREFIX)"
  exit 1
}

bmc_xname_for_index() {
  local idx="$1"
  printf '%s%d\n' "$XNAME_BMC_PREFIX" "$((XNAME_BMC_INDEX_BASE + idx))"
}

xname_for_index() {
  local idx="$1"
  printf '%sn0\n' "$(bmc_xname_for_index "$idx")"
}

domain_name_for_index() {
  local idx="$1"
  local xname

  xname="$(xname_for_index "$idx")"
  printf '%s-%s-%s\n' "$NAME_PREFIX" "$idx" "$xname"
}

boot_artifacts_path_for_test_node_image() {
  if [ -n "$BOOT_ARTIFACTS_PATH" ] && [ -d "$BOOT_ARTIFACTS_PATH" ]; then
    printf '%s\n' "$BOOT_ARTIFACTS_PATH"
    return 0
  fi

  if [ -x "$SCRIPT_DIR/build-boot-artifacts.sh" ]; then
    BOOT_ARTIFACTS_PATH="$("$SCRIPT_DIR/build-boot-artifacts.sh")"
    printf '%s\n' "$BOOT_ARTIFACTS_PATH"
    return 0
  fi

  log_error "BOOT_ARTIFACTS_PATH is not set and build-boot-artifacts.sh is not available"
  exit 1
}

console_ready_pattern_for_boot_image() {
  local artifacts_path

  if [ -n "$NETBOOT_CONSOLE_READY_PATTERN" ]; then
    printf '%s\n' "$NETBOOT_CONSOLE_READY_PATTERN"
    return 0
  fi

  artifacts_path="$(boot_artifacts_path_for_test_node_image)"
  resolve_boot_image_metadata "$artifacts_path" || return 1
  printf '%s\n' "$BOOT_IMAGE_CONSOLE_READY_PATTERN"
}

init_xname_layout
NETBOOT_CONSOLE_READY_PATTERN="$(console_ready_pattern_for_boot_image)"

require_command docker "compose runtime control"

if [ ! -f "$COMPOSE_FILE" ]; then
  log_error "compose file not found: $COMPOSE_FILE"
  log_error "run 'make deploy METHOD=compose' first"
  exit 1
fi

if [ ! -f "$SECRETS_FILE" ]; then
  log_error "secrets file not found: $SECRETS_FILE"
  log_error "run 'make deploy METHOD=compose' first"
  exit 1
fi

# shellcheck disable=SC1090
. "$SECRETS_FILE"

LIBVIRT_BMC_USER="${EXPLICIT_LIBVIRT_BMC_USER:-${LIBVIRT_BMC_USER:-admin}}"
LIBVIRT_BMC_PASSWORD="${EXPLICIT_LIBVIRT_BMC_PASSWORD:-${LIBVIRT_BMC_PASSWORD:-password}}"

sudo_cmd="$(_sudo_noninteractive_cmd)"

libvirt_virsh() {
  # shellcheck disable=SC2086
  $sudo_cmd virsh --connect "$LIBVIRT_URI" "$@"
}

libvirt_virt_install() {
  # shellcheck disable=SC2086
  $sudo_cmd virt-install --connect "$LIBVIRT_URI" "$@"
}

libvirt_qemu_img() {
  # shellcheck disable=SC2086
  $sudo_cmd qemu-img "$@"
}

domain_exists() {
  libvirt_virsh dominfo "$1" >/dev/null 2>&1
}

domain_mac() {
  local domain_name="$1"
  libvirt_virsh domiflist "$domain_name" \
    | awk -v net="$NETWORK_NAME" '$2 == "network" && $3 == net {print $5; exit}'
}

domain_state() {
  libvirt_virsh domstate "$1" 2>/dev/null | tr -d '\r' | xargs
}

compose_method_uses_libvirt_bmc() {
  [ "$METHOD" = "compose" ]
}

domain_uuid() {
  libvirt_virsh domuuid "$1" 2>/dev/null | tr -d '\r' | xargs
}

bmc_ip_for_index() {
  local idx="$1"
  local subnet host

  subnet=$((idx / 254))
  host=$(((idx % 254) + 1))

  if [ "$subnet" -gt 254 ]; then
    log_error "index $idx is too large for deterministic libvirt BMC IP allocation"
    exit 1
  fi

  printf '127.84.%d.%d\n' "$subnet" "$host"
}

bmc_container_name() {
  local domain_name="$1"
  printf '%s-%s\n' "$LIBVIRT_BMC_CONTAINER_PREFIX" "$domain_name"
}

wait_for_compose_libvirt_bmc() {
  local bmc_ip="$1"
  local attempt=1
  local url="https://${bmc_ip}/redfish/v1/"

  log_info "waiting for Redfish BMC endpoint ${url}"
  while [ "$attempt" -le "$LIBVIRT_BMC_READY_ATTEMPTS" ]; do
    if curl -skfu "${LIBVIRT_BMC_USER}:${LIBVIRT_BMC_PASSWORD}" \
      --max-time 5 "$url" >/dev/null 2>&1; then
      log_info "Redfish BMC endpoint is ready at ${url}"
      return 0
    fi

    sleep "$LIBVIRT_BMC_READY_INTERVAL"
    attempt=$((attempt + 1))
  done

  log_error "Redfish BMC endpoint never became ready at ${url}"
  return 1
}

component_endpoint_ready() {
  local xname="$1"
  local bmc_xname="$2"
  local response

  response="$(curl -skfG "https://${SMD_HOST}:${SMD_PORT}/hsm/v2/Inventory/ComponentEndpoints" \
    --data-urlencode "id=${xname}" 2>/dev/null || true)"
  [ -n "$response" ] || return 1

  printf '%s' "$response" | jq -e \
    --arg xname "$xname" \
    --arg bmc_xname "$bmc_xname" \
    '.ComponentEndpoints | any(.ID == $xname and .RedfishEndpointID == $bmc_xname and .Enabled == true)' \
    >/dev/null
}

wait_for_component_endpoint() {
  local xname="$1"
  local bmc_xname="$2"
  local attempt=1

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would wait for SMD ComponentEndpoint ${xname} via ${bmc_xname}"
    return 0
  fi

  log_info "waiting for SMD ComponentEndpoint ${xname} via ${bmc_xname}"
  while [ "$attempt" -le "$HSM_DISCOVERY_ATTEMPTS" ]; do
    if component_endpoint_ready "$xname" "$bmc_xname"; then
      log_info "SMD ComponentEndpoint is ready for ${xname}"
      return 0
    fi

    sleep "$HSM_DISCOVERY_INTERVAL"
    attempt=$((attempt + 1))
  done

  log_error "SMD ComponentEndpoint never became ready for ${xname} via ${bmc_xname}"
  return 1
}

pcs_power_status_ready() {
  local xname="$1"
  local response

  response="$(curl -fsS "$PCS_POWER_STATUS_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"xnames\":[\"${xname}\"]}" 2>/dev/null || true)"
  [ -n "$response" ] || return 1

  printf '%s' "$response" | jq -e \
    --arg xname "$xname" \
    '.status | any(.xname == $xname and .managementState == "available")' \
    >/dev/null
}

wait_for_pcs_power_status() {
  local xname="$1"
  local attempt=1

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would wait for PCS power-status for ${xname}"
    return 0
  fi

  log_info "waiting for PCS power-status for ${xname}"
  while [ "$attempt" -le "$PCS_READY_ATTEMPTS" ]; do
    if pcs_power_status_ready "$xname"; then
      log_info "PCS power-status is ready for ${xname}"
      return 0
    fi

    sleep "$PCS_READY_INTERVAL"
    attempt=$((attempt + 1))
  done

  log_error "PCS power-status never became ready for ${xname}"
  return 1
}

ensure_compose_libvirt_bmc() {
  local domain_name="$1"
  local domain_identity="$2"
  local bmc_ip="$3"
  local container_name

  if ! compose_method_uses_libvirt_bmc; then
    return 0
  fi

  container_name="$(bmc_container_name "$domain_name")"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would run ${container_name} for ${domain_name} at ${bmc_ip}:${LIBVIRT_BMC_LISTEN_PORT}"
    return 0
  fi

  require_command docker "compose libvirt Redfish BMC containers"
  if ! docker_daemon_reachable; then
    log_error "docker daemon is not reachable for libvirt Redfish BMC container management"
    exit 1
  fi

  docker rm -f "$container_name" >/dev/null 2>&1 || true
  docker run -d \
    --name "$container_name" \
    --restart unless-stopped \
    --network host \
    -e "SUSHY_EMULATOR_ALLOWED_INSTANCES=${domain_identity}" \
    -e "SUSHY_EMULATOR_LIBVIRT_URI=${LIBVIRT_URI}" \
    -e "SUSHY_EMULATOR_LISTEN_IP=${bmc_ip}" \
    -e "SUSHY_EMULATOR_LISTEN_PORT=${LIBVIRT_BMC_LISTEN_PORT}" \
    -e "SUSHY_EMULATOR_PASSWORD=${LIBVIRT_BMC_PASSWORD}" \
    -e "SUSHY_EMULATOR_SSL_COMMON_NAME=${bmc_ip}" \
    -e "SUSHY_EMULATOR_USERNAME=${LIBVIRT_BMC_USER}" \
    -v "${LIBVIRT_BMC_SOCKET_PATH}:/var/run/libvirt" \
    "$LIBVIRT_BMC_IMAGE" >/dev/null

  wait_for_compose_libvirt_bmc "$bmc_ip"
}

mac_for_index() {
  local idx="$1"
  if [ "$idx" -gt 255 ]; then
    log_error "index $idx is too large for deterministic MAC generation"
    exit 1
  fi
  printf '52:54:00:ca:11:%02x\n' "$idx"
}

ip_for_index() {
  local idx="$1"
  local last_octet
  last_octet=$((VM_IP_START + idx))
  if [ "$last_octet" -gt 254 ]; then
    log_error "generated IP host octet $last_octet exceeds subnet capacity"
    exit 1
  fi
  printf '%s.%s\n' "${HOST_IP%.*}" "$last_octet"
}

ensure_disk_dir() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would create disk directory $VM_DISK_DIR"
    return 0
  fi
  # shellcheck disable=SC2086
  $sudo_cmd mkdir -p "$VM_DISK_DIR"
}

ensure_vm_disk() {
  local disk_path="$1"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would ensure VM disk $disk_path (${VM_DISK_SIZE})"
    return 0
  fi

  if ! $sudo_cmd test -f "$disk_path"; then
    log_info "creating VM disk $disk_path (${VM_DISK_SIZE})"
    libvirt_qemu_img create -f qcow2 "$disk_path" "$VM_DISK_SIZE" >/dev/null
  fi
}

create_domain_xml() {
  local domain_name="$1"
  local disk_path="$2"
  local mac="$3"
  local xml_path="$4"

  libvirt_virt_install \
    --name "$domain_name" \
    --memory "$VM_MEMORY_MIB" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --osinfo detect=off,name=generic \
    --disk "path=${disk_path},format=qcow2,bus=virtio" \
    --network "network=${NETWORK_NAME},model=virtio,mac=${mac}" \
    --boot "network,hd,menu=on" \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import \
    --print-xml > "$xml_path"
}

ensure_domain_defined() {
  local domain_name="$1"
  local disk_path="$2"
  local mac="$3"
  local xml_path

  if domain_exists "$domain_name"; then
    log_info "domain $domain_name already exists"
    return 0
  fi

  ensure_vm_disk "$disk_path"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would define domain $domain_name on network $NETWORK_NAME"
    return 0
  fi

  xml_path="$(mktemp)"
  create_domain_xml "$domain_name" "$disk_path" "$mac" "$xml_path"
  log_info "defining domain $domain_name on network $NETWORK_NAME"
  libvirt_virsh define "$xml_path" >/dev/null
  libvirt_virsh autostart "$domain_name" >/dev/null || true
  rm -f "$xml_path"
}

ensure_domain_started_fresh() {
  local domain_name="$1"
  local state

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would power-cycle domain $domain_name"
    return 0
  fi

  state="$(domain_state "$domain_name" || true)"
  case "$state" in
    running|in\ shutdown|paused|blocked)
      log_info "stopping domain $domain_name for a fresh PXE boot"
      libvirt_virsh destroy "$domain_name" >/dev/null || true
      ;;
  esac

  log_info "starting domain $domain_name"
  libvirt_virsh start "$domain_name" >/dev/null
}

bootscript_ready() {
  local mac="$1"
  local first_stage
  local second_stage
  local timestamp
  local base_url="http://${BOOTSCRIPT_HOST}:${BOOTSCRIPT_PORT}"

  first_stage="$(curl -fsS -G "${base_url}/boot/v1/bootscript" \
    --data-urlencode "mac=${mac}" 2>/dev/null || true)"
  [ -n "$first_stage" ] || return 1
  printf '%s' "$first_stage" | grep -q '/apis/bss/boot/v1/bootscript' || return 1

  timestamp="$(date +%s)"
  second_stage="$(curl -fsS -G "${base_url}/apis/bss/boot/v1/bootscript" \
    --data-urlencode "mac=${mac}" \
    --data-urlencode "arch=x86_64" \
    --data-urlencode "ts=${timestamp}" 2>/dev/null || true)"

  [ -n "$second_stage" ] || return 1
  printf '%s' "$second_stage" | grep -q 'kernel --name kernel' || return 1
  printf '%s' "$second_stage" | grep -q 'initrd --name initrd' || return 1
}

wait_for_bootscript() {
  local mac="$1"
  local xname="$2"
  local attempt=1

  log_info "waiting for BSS bootscript for $xname ($mac)"
  while [ "$attempt" -le "$BOOTSCRIPT_ATTEMPTS" ]; do
    if bootscript_ready "$mac"; then
      log_info "BSS bootscript is ready for $xname"
      return 0
    fi
    sleep "$BOOTSCRIPT_INTERVAL"
    attempt=$((attempt + 1))
  done

  log_error "BSS bootscript never became ready for $xname ($mac)"
  return 1
}

refresh_compose_kea() {
  log_info "ensuring compose Kea services are ready on ${NETWORK_BRIDGE}"
  docker_compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" \
    up -d --no-deps kea kea-sync
  CHECK_KEA=true PXE_INTERFACE="$NETWORK_BRIDGE" COMPOSE_FILE="$COMPOSE_FILE" \
    SECRETS_FILE="$SECRETS_FILE" "$SCRIPT_DIR/health-check.sh" $DRY_RUN_FLAG
}

trigger_kea_sync() {
  log_info "triggering kea-sync reconciliation"
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would POST http://localhost:${KEA_SYNC_PORT}/v1/sync"
    return 0
  fi

  curl -fsS -X POST "http://localhost:${KEA_SYNC_PORT}/v1/sync" >/dev/null
}

ensure_bss_defaults() {
  log_info "ensuring default BSS boot parameters are present"
  "$SCRIPT_DIR/register-bss-defaults.sh" $DRY_RUN_FLAG
}

prepare_runtime() {
  ensure_disk_dir
  ensure_libvirt_network "$NETWORK_NAME" "$NETWORK_BRIDGE" "$HOST_IP" "$PXE_CIDR"
  ensure_bridge_carrier "$NETWORK_BRIDGE"
  refresh_compose_kea
  ensure_bss_defaults
}

register_nodes() {
  for idx in "${!xnames[@]}"; do
    REDFISH_BMC_USER="$LIBVIRT_BMC_USER" \
    REDFISH_BMC_PASSWORD="$LIBVIRT_BMC_PASSWORD" \
    SMD_HOST="$SMD_HOST" SMD_PORT="$SMD_PORT" \
      "$SCRIPT_DIR/register-nodes.sh" \
        --xname "${xnames[$idx]}" --mac "${macs[$idx]}" --ip "${ips[$idx]}" \
        --bmc-ip "${bmc_ips[$idx]}" --bmc-xname "${bmc_xnames[$idx]}" \
        $DRY_RUN_FLAG
  done
}

reconcile_dhcp_runtime() {
  trigger_kea_sync
}

prepare_runtime

if [ "$DRY_RUN" != "true" ]; then
  mkdir -p "$(dirname "$MANIFEST_FILE")"
  printf 'xname,mac,ip,bmc_ip,bmc_xname,domain\n' > "$MANIFEST_FILE"
fi

domain_names=()
xnames=()
macs=()
ips=()
bmc_ips=()
bmc_xnames=()

for offset in $(seq 0 $((COUNT - 1))); do
  idx=$((START_INDEX + offset))
  xname="$(xname_for_index "$idx")"
  domain_name="$(domain_name_for_index "$idx")"
  ip_addr="$(ip_for_index "$idx")"
  disk_path="${VM_DISK_DIR}/${domain_name}.qcow2"
  desired_mac="$(mac_for_index "$idx")"
  bmc_ip="-"
  bmc_xname="-"

  ensure_domain_defined "$domain_name" "$disk_path" "$desired_mac"

  actual_mac="$desired_mac"
  if [ "$DRY_RUN" != "true" ] && domain_exists "$domain_name"; then
    actual_mac="$(domain_mac "$domain_name")"
    if [ -z "$actual_mac" ]; then
      log_error "domain $domain_name is not attached to libvirt network $NETWORK_NAME"
      exit 1
    fi
  fi

  if compose_method_uses_libvirt_bmc; then
    bmc_ip="$(bmc_ip_for_index "$idx")"
    bmc_xname="$(bmc_xname_for_index "$idx")"
    ensure_compose_libvirt_bmc "$domain_name" "$(domain_uuid "$domain_name")" "$bmc_ip"
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would register ${xname} (${actual_mac}, ${ip_addr}, ${bmc_xname})"
  else
    printf '%s,%s,%s,%s,%s,%s\n' "$xname" "$actual_mac" "$ip_addr" "$bmc_ip" "$bmc_xname" "$domain_name" >> "$MANIFEST_FILE"
  fi

  domain_names+=("$domain_name")
  xnames+=("$xname")
  macs+=("$actual_mac")
  ips+=("$ip_addr")
  bmc_ips+=("$bmc_ip")
  bmc_xnames+=("$bmc_xname")
done

register_nodes
if compose_method_uses_libvirt_bmc; then
  for idx in "${!xnames[@]}"; do
    wait_for_component_endpoint "${xnames[$idx]}" "${bmc_xnames[$idx]}"
  done
fi
reconcile_dhcp_runtime
if compose_method_uses_libvirt_bmc; then
  for idx in "${!xnames[@]}"; do
    wait_for_pcs_power_status "${xnames[$idx]}"
  done
fi

for idx in "${!xnames[@]}"; do
  if [ "$DRY_RUN" != "true" ]; then
    wait_for_bootscript "${macs[$idx]}" "${xnames[$idx]}"
  fi
done

for domain_name in "${domain_names[@]}"; do
  ensure_domain_started_fresh "$domain_name"
done

if [ "$DRY_RUN" = "true" ]; then
  log_info "[dry-run] would finish with ${COUNT} OpenCHAMI test VMs"
else
  log_info "OpenCHAMI test VMs are defined, registered, and started"
  log_info "VM manifest written to ${MANIFEST_FILE}"
fi
