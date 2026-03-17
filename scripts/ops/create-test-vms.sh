#!/usr/bin/env bash
# create-test-vms.sh — Create libvirt test VMs and register them for OpenCHAMI PXE boot.
# Usage: ./create-test-vms.sh --count N [--start-index N] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"

COUNT="${COUNT:-1}"
START_INDEX="${START_INDEX:-0}"
NAME_PREFIX="${NAME_PREFIX:-ochami-test-node}"
XNAME_PREFIX="${XNAME_PREFIX:-x1000c0s0b0n}"
LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
NETWORK_NAME="${NETWORK_NAME:-ochami-pxe-net}"
NETWORK_BRIDGE="${NETWORK_BRIDGE:-virbr-ochami}"
HOST_IP="${HOST_IP:-192.168.100.1}"
PXE_CIDR="${PXE_CIDR:-24}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-2048}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_SIZE="${VM_DISK_SIZE:-20G}"
VM_DISK_DIR="${VM_DISK_DIR:-/var/lib/libvirt/images/ochami}"
VM_IP_START="${VM_IP_START:-100}"
BOOTSCRIPT_ATTEMPTS="${BOOTSCRIPT_ATTEMPTS:-12}"
BOOTSCRIPT_INTERVAL="${BOOTSCRIPT_INTERVAL:-5}"
COMPOSE_DIR="${COMPOSE_DIR:-${PROJECT_ROOT}/ochami-docker-compose}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.generated.yml"
SECRETS_FILE="${OPENCHAMI_SECRETS:-${PROJECT_ROOT}/.tmp/openchami-secrets.env}"
MANIFEST_FILE="${MANIFEST_FILE:-${PROJECT_ROOT}/.tmp/ochami-test-vms.csv}"
KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"

usage() {
  cat <<EOF
Usage: $0 --count N [options]

Options:
  --count N            Number of test VMs to ensure exist
  --start-index N      Starting index for VM names, xnames, MACs, and reserved IPs
  --name-prefix NAME   Domain name prefix (default: ${NAME_PREFIX})
  --xname-prefix NAME  Xname prefix (default: ${XNAME_PREFIX})
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

if [ "$COUNT" -eq 0 ]; then
  log_info "no VMs requested; nothing to do"
  exit 0
fi

DRY_RUN_FLAG=""
if [ "$DRY_RUN" = "true" ]; then
  DRY_RUN_FLAG="--dry-run"
fi

require_command virsh "libvirt management"
require_command virt-install "libvirt VM creation"
require_command qemu-img "disk image creation"
require_command docker "compose runtime control"
require_command jq "JSON processing"

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

  first_stage="$(curl -fsS -G "http://localhost/boot/v1/bootscript" \
    --data-urlencode "mac=${mac}" 2>/dev/null || true)"
  [ -n "$first_stage" ] || return 1
  printf '%s' "$first_stage" | grep -q '/apis/bss/boot/v1/bootscript' || return 1

  timestamp="$(date +%s)"
  second_stage="$(curl -fsS -G "http://localhost/apis/bss/boot/v1/bootscript" \
    --data-urlencode "mac=${mac}" \
    --data-urlencode "arch=x86_64" \
    --data-urlencode "ts=${timestamp}" 2>/dev/null || true)"

  [ -n "$second_stage" ] || return 1
  printf '%s' "$second_stage" | grep -q 'kernel --name kernel' || return 1
  printf '%s' "$second_stage" | grep -q 'initrd --name initrd' || return 1
  printf '%s' "$second_stage" | grep -q 'init=' || return 1
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
  run_cmd docker compose -f "$COMPOSE_FILE" --env-file "$SECRETS_FILE" \
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

ensure_disk_dir
ensure_libvirt_network "$NETWORK_NAME" "$NETWORK_BRIDGE" "$HOST_IP" "$PXE_CIDR"
ensure_bridge_carrier "$NETWORK_BRIDGE"
refresh_compose_kea
ensure_bss_defaults

if [ "$DRY_RUN" != "true" ]; then
  mkdir -p "$(dirname "$MANIFEST_FILE")"
  printf 'xname,mac,ip,bmc_ip,domain\n' > "$MANIFEST_FILE"
fi

domain_names=()
xnames=()
macs=()
ips=()

for offset in $(seq 0 $((COUNT - 1))); do
  idx=$((START_INDEX + offset))
  domain_name="${NAME_PREFIX}-${idx}"
  xname="${XNAME_PREFIX}${idx}"
  ip_addr="$(ip_for_index "$idx")"
  disk_path="${VM_DISK_DIR}/${domain_name}.qcow2"
  desired_mac="$(mac_for_index "$idx")"

  ensure_domain_defined "$domain_name" "$disk_path" "$desired_mac"

  actual_mac="$desired_mac"
  if [ "$DRY_RUN" != "true" ] && domain_exists "$domain_name"; then
    actual_mac="$(domain_mac "$domain_name")"
    if [ -z "$actual_mac" ]; then
      log_error "domain $domain_name is not attached to libvirt network $NETWORK_NAME"
      exit 1
    fi
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would register ${xname} (${actual_mac}, ${ip_addr})"
  else
    printf '%s,%s,%s,-,%s\n' "$xname" "$actual_mac" "$ip_addr" "$domain_name" >> "$MANIFEST_FILE"
  fi

  domain_names+=("$domain_name")
  xnames+=("$xname")
  macs+=("$actual_mac")
  ips+=("$ip_addr")
done

registration_csv="$(mktemp)"
trap 'rm -f "$registration_csv"' EXIT

{
  printf 'xname,mac,ip,bmc_ip\n'
  for idx in "${!xnames[@]}"; do
    printf '%s,%s,%s,-\n' "${xnames[$idx]}" "${macs[$idx]}" "${ips[$idx]}"
  done
} > "$registration_csv"

"$SCRIPT_DIR/register-nodes.sh" --nodes-csv "$registration_csv" $DRY_RUN_FLAG
trigger_kea_sync

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
