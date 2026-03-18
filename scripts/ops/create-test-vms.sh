#!/usr/bin/env bash
# create-test-vms.sh — Create libvirt test VMs and register them for OpenCHAMI PXE boot.
# Usage: ./create-test-vms.sh --count N [--start-index N] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"
NIX_FLAKE_REF="${OPENCHAMI_NIX_FLAKE_REF:-$(nix_flake_ref "$PROJECT_ROOT")}"

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
COMPOSE_DIR="${COMPOSE_DIR:-${PROJECT_ROOT}/ochami-docker-compose}"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.generated.yml"
SECRETS_FILE="${OPENCHAMI_SECRETS:-${PROJECT_ROOT}/.tmp/openchami-secrets.env}"
MANIFEST_FILE="${MANIFEST_FILE:-${PROJECT_ROOT}/.tmp/ochami-test-vms.csv}"
KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"
DEFAULT_LAB_VM_STATE_DIR="${PROJECT_ROOT}/.tmp/lab-vm"
if [ "$(uname -s)" = "Linux" ]; then
  DEFAULT_LAB_VM_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/openchami/lab-vm"
fi
LAB_VM_STATE_DIR="${LAB_VM_STATE_DIR:-${DEFAULT_LAB_VM_STATE_DIR}}"
LAB_VM_NETWORK_NAME="${LAB_VM_NETWORK_NAME:-openchami-lab-net}"
LAB_VM_NETWORK_BRIDGE="${LAB_VM_NETWORK_BRIDGE:-virbr-ochlab}"
LAB_VM_LIBVIRT_URI="${LAB_VM_LIBVIRT_URI:-$(default_lab_vm_libvirt_uri)}"
LAB_VM_CONTROLLER_DOMAIN="${LAB_VM_CONTROLLER_DOMAIN:-openchami-controller}"
LAB_VM_CONTROLLER_HTTP_PORT="${LAB_VM_CONTROLLER_HTTP_PORT:-28000}"
LAB_VM_CONTROLLER_BSS_PORT="${LAB_VM_CONTROLLER_BSS_PORT:-29778}"
LAB_VM_CONTROLLER_SMD_PORT="${LAB_VM_CONTROLLER_SMD_PORT:-29779}"
LAB_VM_SHARED_NET_MCAST="${LAB_VM_SHARED_NET_MCAST:-230.0.0.1:31337}"
LAB_VM_NODE_STATE_DIR="${LAB_VM_NODE_STATE_DIR:-${LAB_VM_STATE_DIR}/compute}"
LAB_VM_COMPUTE_DISK_DIR="${LAB_VM_COMPUTE_DISK_DIR:-${LAB_VM_NODE_STATE_DIR}/disks}"
LAB_VM_COMPUTE_PID_DIR="${LAB_VM_COMPUTE_PID_DIR:-${LAB_VM_NODE_STATE_DIR}/pids}"
LAB_VM_COMPUTE_LOG_DIR="${LAB_VM_COMPUTE_LOG_DIR:-${LAB_VM_NODE_STATE_DIR}/logs}"
LAB_VM_COMPUTE_BOOT_CACHE_DIR="${LAB_VM_COMPUTE_BOOT_CACHE_DIR:-${LAB_VM_NODE_STATE_DIR}/boot}"
LAB_VM_COMPUTE_BOOT_ATTEMPTS="${LAB_VM_COMPUTE_BOOT_ATTEMPTS:-90}"
LAB_VM_COMPUTE_BOOT_INTERVAL="${LAB_VM_COMPUTE_BOOT_INTERVAL:-2}"
LAB_VM_DIRECT_QEMU_MACHINE="${LAB_VM_DIRECT_QEMU_MACHINE:-q35,accel=tcg}"
LAB_VM_DIRECT_GUEST_HOST="${LAB_VM_DIRECT_GUEST_HOST:-10.0.2.2}"
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
  --method METHOD      Runtime backend: compose or lab-vm (default: ${METHOD})
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
  lab-vm)
    LIBVIRT_URI="${LIBVIRT_URI:-${LAB_VM_LIBVIRT_URI}}"
    NETWORK_NAME="${NETWORK_NAME:-${LAB_VM_NETWORK_NAME}}"
    NETWORK_BRIDGE="${NETWORK_BRIDGE:-${LAB_VM_NETWORK_BRIDGE}}"
    HOST_IP="${HOST_IP:-192.168.100.1}"
    PXE_CIDR="${PXE_CIDR:-24}"
    BOOTSCRIPT_HOST="${BOOTSCRIPT_HOST:-127.0.0.1}"
    BOOTSCRIPT_PORT="${BOOTSCRIPT_PORT:-${LAB_VM_CONTROLLER_HTTP_PORT}}"
    SMD_HOST="${SMD_HOST:-127.0.0.1}"
    SMD_PORT="${SMD_PORT:-${LAB_VM_CONTROLLER_SMD_PORT}}"
    ;;
  *)
    log_error "unknown method: $METHOD"
    usage
    exit 1
    ;;
esac

lab_vm_uses_darwin_libvirt_boot_assets() {
  [ "$METHOD" = "lab-vm" ] && [ "$(uname -s)" = "Darwin" ]
}

if lab_vm_uses_darwin_libvirt_boot_assets && [ "$VM_DISK_DIR" = "/var/lib/libvirt/images/ochami" ]; then
  VM_DISK_DIR="$LAB_VM_COMPUTE_DISK_DIR"
fi

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

require_command jq "JSON processing"

require_command virsh "libvirt management"
if ! lab_vm_uses_darwin_libvirt_boot_assets; then
  require_command virt-install "libvirt VM creation"
  require_command qemu-img "disk image creation"
fi

case "$METHOD" in
  compose)
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
    ;;
  lab-vm)
    if lab_vm_uses_darwin_libvirt_boot_assets; then
      require_command nix "Nix is required to build the controller VM runner metadata"
    fi
    "$SCRIPT_DIR/lab-vm.sh" health $DRY_RUN_FLAG
    log_info "using controller VM endpoints http://127.0.0.1:${LAB_VM_CONTROLLER_HTTP_PORT}, http://127.0.0.1:${LAB_VM_CONTROLLER_BSS_PORT}, and https://127.0.0.1:${LAB_VM_CONTROLLER_SMD_PORT}"
    ;;
esac

sudo_cmd=""
if ! libvirt_uri_is_session "$LIBVIRT_URI"; then
  sudo_cmd="$(_sudo_noninteractive_cmd)"
fi

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

lab_vm_controller_vm_artifact() {
  nix build "${NIX_FLAKE_REF}#lab-controller-vm" --no-link --print-out-paths
}

lab_vm_controller_vm_runner() {
  local vm_out="$1"
  printf '%s/bin/run-openchami-controller-vm\n' "$vm_out"
}

direct_qemu_domain_pid_file() {
  printf '%s/%s.pid\n' "$LAB_VM_COMPUTE_PID_DIR" "$1"
}

direct_qemu_domain_serial_log() {
  printf '%s/%s.serial.log\n' "$LAB_VM_COMPUTE_LOG_DIR" "$1"
}

direct_qemu_domain_boot_dir() {
  printf '%s/%s\n' "$LAB_VM_COMPUTE_BOOT_CACHE_DIR" "$1"
}

prepare_direct_qemu_runtime() {
  local vm_out runner

  if [ "$DRY_RUN" != "true" ]; then
    mkdir -p "$VM_DISK_DIR" "$LAB_VM_COMPUTE_PID_DIR" "$LAB_VM_COMPUTE_LOG_DIR" \
      "$LAB_VM_COMPUTE_BOOT_CACHE_DIR"
  fi

  if [ -n "${DIRECT_QEMU_BIN:-}" ] && [ -x "${DIRECT_QEMU_BIN:-}" ]; then
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would build controller VM runner metadata for libvirt-managed Darwin compute VMs"
    return 0
  fi

  log_info "building controller VM runner metadata for libvirt-managed Darwin compute VMs..."
  vm_out="$(lab_vm_controller_vm_artifact)"
  if [ -z "$vm_out" ] || [ ! -d "$vm_out" ]; then
    log_error "failed to build controller VM artifact required for libvirt-managed Darwin compute VMs"
    exit 1
  fi

  runner="$(lab_vm_controller_vm_runner "$vm_out")"
  if [ ! -x "$runner" ]; then
    log_error "controller VM runner not found: $runner"
    exit 1
  fi

  DIRECT_QEMU_BIN="$(qemu_system_bin_from_vm_runner "$runner")"
  if [ -z "$DIRECT_QEMU_BIN" ] || [ ! -x "$DIRECT_QEMU_BIN" ]; then
    log_error "failed to determine qemu-system-x86_64 path from $runner"
    exit 1
  fi

  DIRECT_QEMU_IMG_BIN="$(qemu_img_bin_from_vm_runner "$runner")"
  if [ ! -x "$DIRECT_QEMU_IMG_BIN" ]; then
    log_error "failed to determine qemu-img path from $runner"
    exit 1
  fi
}

fetch_direct_qemu_second_stage_bootscript() {
  local mac="$1"
  local timestamp
  local base_url="http://${BOOTSCRIPT_HOST}:${BOOTSCRIPT_PORT}"

  timestamp="$(date +%s)"
  curl -fsS -G "${base_url}/apis/bss/boot/v1/bootscript" \
    --data-urlencode "mac=${mac}" \
    --data-urlencode "arch=x86_64" \
    --data-urlencode "ts=${timestamp}"
}

rewrite_direct_qemu_bootscript() {
  local bootscript="$1"
  local host_ip_pattern="${HOST_IP//./\\.}"

  printf '%s' "$bootscript" | sed \
    -e "s#http://${host_ip_pattern}:80/#http://${LAB_VM_DIRECT_GUEST_HOST}:${LAB_VM_CONTROLLER_HTTP_PORT}/#g" \
    -e "s#http://${host_ip_pattern}/#http://${LAB_VM_DIRECT_GUEST_HOST}:${LAB_VM_CONTROLLER_HTTP_PORT}/#g" \
    -e "s#ds=nocloud-net;s=${host_ip_pattern}/#ds=nocloud-net;s=http://${LAB_VM_DIRECT_GUEST_HOST}:${LAB_VM_CONTROLLER_HTTP_PORT}/cloud-init/#g"
}

rewrite_direct_qemu_bootscript_for_host() {
  local bootscript="$1"
  local host_ip_pattern="${HOST_IP//./\\.}"

  printf '%s' "$bootscript" | sed \
    -e "s#http://${host_ip_pattern}:80/#http://${BOOTSCRIPT_HOST}:${LAB_VM_CONTROLLER_HTTP_PORT}/#g" \
    -e "s#http://${host_ip_pattern}/#http://${BOOTSCRIPT_HOST}:${LAB_VM_CONTROLLER_HTTP_PORT}/#g"
}

extract_direct_qemu_kernel_url() {
  printf '%s\n' "$1" | sed -n 's#^kernel --name kernel \([^ ]*\) .*#\1#p' | head -n 1
}

extract_direct_qemu_kernel_args() {
  printf '%s\n' "$1" | sed -n 's#^kernel --name kernel [^ ]* ##p' | sed 's# || goto .*##' | head -n 1
}

extract_direct_qemu_initrd_url() {
  printf '%s\n' "$1" | sed -n 's#^initrd --name initrd \([^ ]*\).*#\1#p' | head -n 1
}

download_direct_qemu_boot_artifact() {
  local url="$1"
  local out_path="$2"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would download $url to $out_path"
    return 0
  fi

  curl -fsS "$url" -o "$out_path"
}

prepare_direct_qemu_boot_assets() {
  local domain_name="$1"
  local mac="$2"
  local boot_dir bootscript guest_bootscript host_bootscript kernel_url initrd_url kernel_args

  boot_dir="$(direct_qemu_domain_boot_dir "$domain_name")"
  DIRECT_QEMU_KERNEL_PATH="${boot_dir}/vmlinuz"
  DIRECT_QEMU_INITRD_PATH="${boot_dir}/initrd"
  DIRECT_QEMU_KERNEL_ARGS=""

  if [ "$DRY_RUN" != "true" ]; then
    mkdir -p "$boot_dir"
  fi

  bootscript="$(fetch_direct_qemu_second_stage_bootscript "$mac")"
  guest_bootscript="$(rewrite_direct_qemu_bootscript "$bootscript")"
  host_bootscript="$(rewrite_direct_qemu_bootscript_for_host "$bootscript")"

  kernel_url="$(extract_direct_qemu_kernel_url "$host_bootscript")"
  initrd_url="$(extract_direct_qemu_initrd_url "$host_bootscript")"
  kernel_args="$(extract_direct_qemu_kernel_args "$guest_bootscript")"

  if [ -z "$kernel_url" ] || [ -z "$initrd_url" ] || [ -z "$kernel_args" ]; then
    log_error "failed to translate controller bootscript into direct-QEMU boot assets for $domain_name"
    printf '%s\n' "$guest_bootscript" >&2
    return 1
  fi

  DIRECT_QEMU_KERNEL_ARGS="$kernel_args"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would start $domain_name with controller-generated kernel=$kernel_url and initrd=$initrd_url"
    return 0
  fi

  printf '%s\n' "$guest_bootscript" > "${boot_dir}/bootscript.ipxe"
  printf '%s\n' "$DIRECT_QEMU_KERNEL_ARGS" > "${boot_dir}/kernel.args"
  download_direct_qemu_boot_artifact "$kernel_url" "$DIRECT_QEMU_KERNEL_PATH"
  download_direct_qemu_boot_artifact "$initrd_url" "$DIRECT_QEMU_INITRD_PATH"
}

direct_qemu_domain_pid() {
  local domain_name="$1"
  local pid_file

  pid_file="$(direct_qemu_domain_pid_file "$domain_name")"
  if [ ! -f "$pid_file" ]; then
    return 1
  fi

  cat "$pid_file" 2>/dev/null || true
}

direct_qemu_domain_is_running() {
  local domain_name="$1"
  local pid

  pid="$(direct_qemu_domain_pid "$domain_name" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1
}

stop_direct_qemu_domain() {
  local domain_name="$1"
  local pid attempt pid_file

  pid_file="$(direct_qemu_domain_pid_file "$domain_name")"
  pid="$(direct_qemu_domain_pid "$domain_name" 2>/dev/null || true)"

  if [ -z "$pid" ] || ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -f "$pid_file"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would stop direct-QEMU domain $domain_name (pid=$pid)"
    return 0
  fi

  log_info "stopping direct-QEMU domain $domain_name for a fresh PXE boot"
  kill "$pid" >/dev/null 2>&1 || true
  for attempt in $(seq 1 15); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$pid_file"
      return 0
    fi
    sleep 1
  done

  log_warn "direct-QEMU domain $domain_name did not stop after 15s; sending SIGKILL"
  kill -9 "$pid" >/dev/null 2>&1 || true
  rm -f "$pid_file"
}

ensure_direct_qemu_vm_disk() {
  local disk_path="$1"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would ensure VM disk $disk_path (${VM_DISK_SIZE})"
    return 0
  fi

  if [ ! -f "$disk_path" ]; then
    log_info "creating VM disk $disk_path (${VM_DISK_SIZE})"
    "$DIRECT_QEMU_IMG_BIN" create -f qcow2 "$disk_path" "$VM_DISK_SIZE" >/dev/null
  fi
}

start_direct_qemu_domain() {
  local domain_name="$1"
  local disk_path="$2"
  local mac="$3"
  local pid_file serial_log

  pid_file="$(direct_qemu_domain_pid_file "$domain_name")"
  serial_log="$(direct_qemu_domain_serial_log "$domain_name")"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would start direct-QEMU domain $domain_name with controller-generated boot assets"
    return 0
  fi

  prepare_direct_qemu_boot_assets "$domain_name" "$mac"
  rm -f "$pid_file" "$serial_log"
  log_info "starting direct-QEMU domain $domain_name with controller-generated boot assets"
  "$DIRECT_QEMU_BIN" \
    -name "$domain_name" \
    -machine "$LAB_VM_DIRECT_QEMU_MACHINE" \
    -cpu max \
    -m "$VM_MEMORY_MIB" \
    -smp "$VM_VCPUS" \
    -device virtio-rng-pci \
    -drive "if=virtio,format=qcow2,file=${disk_path}" \
    -netdev "user,id=user.0" \
    -device "e1000,netdev=user.0,mac=${mac}" \
    -kernel "$DIRECT_QEMU_KERNEL_PATH" \
    -initrd "$DIRECT_QEMU_INITRD_PATH" \
    -append "$DIRECT_QEMU_KERNEL_ARGS" \
    -display none \
    -serial "file:${serial_log}" \
    -monitor none \
    -pidfile "$pid_file" \
    -daemonize

  if ! direct_qemu_domain_is_running "$domain_name"; then
    log_error "direct-QEMU domain $domain_name failed to stay running"
    [ -f "$serial_log" ] && tail -n 60 "$serial_log" >&2
    return 1
  fi
}

wait_for_direct_qemu_console() {
  local domain_name="$1"
  local serial_log attempt=1

  serial_log="$(direct_qemu_domain_serial_log "$domain_name")"

  log_info "waiting for direct-QEMU console output from $domain_name"
  while [ "$attempt" -le "$LAB_VM_COMPUTE_BOOT_ATTEMPTS" ]; do
    if [ -f "$serial_log" ] && grep -Eq 'Welcome to NixOS kexec|ochami-netboot login|nixos@ochami-netboot' "$serial_log"; then
      log_info "direct-QEMU console output confirms $domain_name reached ochami-netboot"
      return 0
    fi

    if ! direct_qemu_domain_is_running "$domain_name"; then
      log_error "direct-QEMU domain $domain_name exited before reaching ochami-netboot"
      [ -f "$serial_log" ] && tail -n 60 "$serial_log" >&2
      return 1
    fi

    sleep "$LAB_VM_COMPUTE_BOOT_INTERVAL"
    attempt=$((attempt + 1))
  done

  log_error "direct-QEMU console output never confirmed ochami-netboot for $domain_name"
  [ -f "$serial_log" ] && tail -n 60 "$serial_log" >&2
  return 1
}

darwin_libvirt_console_probe() {
  local domain_name="$1"
  local probe_log="$2"
  local probe_pid
  local console_pattern script_pattern
  local virsh_bin

  if ! command_exists script; then
    return 1
  fi

  virsh_bin="$(command -v virsh)"
  if [ -z "$virsh_bin" ]; then
    return 1
  fi

  console_pattern="virsh --connect ${LIBVIRT_URI} console ${domain_name}"
  script_pattern="script -q /dev/null ${virsh_bin} --connect ${LIBVIRT_URI} console ${domain_name}"
  rm -f "$probe_log"
  (
    { sleep 2; printf '\n'; sleep 2; } \
      | script -q /dev/null "$virsh_bin" --connect "$LIBVIRT_URI" console "$domain_name" >"$probe_log" 2>&1
  ) &
  probe_pid=$!

  sleep 20
  pkill -f "$console_pattern" >/dev/null 2>&1 || true
  pkill -f "$script_pattern" >/dev/null 2>&1 || true
  kill "$probe_pid" >/dev/null 2>&1 || true
  wait "$probe_pid" 2>/dev/null || true
}

render_darwin_lab_vm_domain_xml() {
  local domain_name="$1"
  local disk_path="$2"
  local mac="$3"
  local xml_path="$4"
  local serial_log

  serial_log="$(direct_qemu_domain_serial_log "$domain_name")"

  cat >"$xml_path" <<EOF
<domain type='qemu'>
  <name>$(printf '%s' "$domain_name" | xml_escape)</name>
  <memory unit='MiB'>$(printf '%s' "$VM_MEMORY_MIB" | xml_escape)</memory>
  <vcpu>$(printf '%s' "$VM_VCPUS" | xml_escape)</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
    <kernel>$(printf '%s' "$DIRECT_QEMU_KERNEL_PATH" | xml_escape)</kernel>
    <initrd>$(printf '%s' "$DIRECT_QEMU_INITRD_PATH" | xml_escape)</initrd>
    <cmdline>$(printf '%s' "$DIRECT_QEMU_KERNEL_ARGS" | xml_escape)</cmdline>
  </os>
  <features>
    <acpi/>
  </features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>$(printf '%s' "$DIRECT_QEMU_BIN" | xml_escape)</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='$(printf '%s' "$disk_path" | xml_escape)'/>
      <target dev='vda' bus='virtio'/>
      <serial>root</serial>
    </disk>
    <interface type='user'>
      <mac address='$(printf '%s' "$mac" | xml_escape)'/>
      <model type='e1000'/>
    </interface>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <serial type='pty'>
      <log file='$(printf '%s' "$serial_log" | xml_escape)' append='off'/>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
EOF
}

start_darwin_libvirt_domain() {
  local domain_name="$1"
  local disk_path="$2"
  local mac="$3"
  local serial_log xml_path state

  serial_log="$(direct_qemu_domain_serial_log "$domain_name")"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would define libvirt session domain $domain_name with controller-generated boot assets"
    return 0
  fi

  prepare_direct_qemu_boot_assets "$domain_name" "$mac"
  rm -f "$serial_log"
  xml_path="$(mktemp "${LAB_VM_STATE_DIR}/${domain_name}.XXXXXX.xml")"
  trap 'rm -f "$xml_path"' RETURN
  render_darwin_lab_vm_domain_xml "$domain_name" "$disk_path" "$mac" "$xml_path"

  if domain_exists "$domain_name"; then
    state="$(domain_state "$domain_name" || true)"
    if [ "$state" = "running" ]; then
      log_info "stopping libvirt session domain $domain_name for a fresh controller-driven boot"
      libvirt_virsh destroy "$domain_name" >/dev/null 2>&1 || true
    fi
    libvirt_virsh undefine "$domain_name" >/dev/null 2>&1 || true
  fi

  log_info "defining libvirt session domain $domain_name with controller-generated boot assets"
  libvirt_virsh define "$xml_path" >/dev/null
  libvirt_virsh autostart "$domain_name" >/dev/null || true
  log_info "starting libvirt session domain $domain_name"
  libvirt_virsh start "$domain_name" >/dev/null

  rm -f "$xml_path"
  trap - RETURN

  if [ "$(domain_state "$domain_name" 2>/dev/null || true)" != "running" ]; then
    log_error "libvirt session domain $domain_name failed to stay running"
    [ -f "$serial_log" ] && tail -n 60 "$serial_log" >&2
    return 1
  fi
}

wait_for_darwin_libvirt_console() {
  local domain_name="$1"
  local serial_log probe_log=""
  local attempt=1

  serial_log="$(direct_qemu_domain_serial_log "$domain_name")"
  if command_exists script; then
    probe_log="$(mktemp)"
  fi

  log_info "waiting for libvirt session console output from $domain_name"
  while [ "$attempt" -le "$LAB_VM_COMPUTE_BOOT_ATTEMPTS" ]; do
    if [ -f "$serial_log" ] && grep -Eq 'Welcome to NixOS kexec|ochami-netboot login|nixos@ochami-netboot|systemd-ssh-generator' "$serial_log"; then
      [ -n "$probe_log" ] && rm -f "$probe_log"
      log_info "libvirt session console output confirms $domain_name reached ochami-netboot"
      return 0
    fi

    if [ -n "$probe_log" ] && [ $((attempt % 5)) -eq 1 ]; then
      darwin_libvirt_console_probe "$domain_name" "$probe_log"
      if [ -f "$probe_log" ] && grep -Eq 'Welcome to NixOS kexec|ochami-netboot login|nixos@ochami-netboot' "$probe_log"; then
        cat "$probe_log" >>"$serial_log" 2>/dev/null || true
        rm -f "$probe_log"
        log_info "libvirt session console probe confirms $domain_name reached ochami-netboot"
        return 0
      fi
    fi

    if [ "$(domain_state "$domain_name" 2>/dev/null || true)" != "running" ]; then
      [ -n "$probe_log" ] && rm -f "$probe_log"
      log_error "libvirt session domain $domain_name exited before reaching ochami-netboot"
      [ -f "$serial_log" ] && tail -n 60 "$serial_log" >&2
      return 1
    fi

    sleep "$LAB_VM_COMPUTE_BOOT_INTERVAL"
    attempt=$((attempt + 1))
  done

  [ -n "$probe_log" ] && rm -f "$probe_log"
  log_error "libvirt session console output never confirmed ochami-netboot for $domain_name"
  [ -f "$serial_log" ] && tail -n 60 "$serial_log" >&2
  return 1
}

run_darwin_libvirt_lab_vms() {
  prepare_direct_qemu_runtime

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
    actual_mac="$(mac_for_index "$idx")"

    ensure_direct_qemu_vm_disk "$disk_path"

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

  register_nodes

  for idx in "${!xnames[@]}"; do
    if [ "$DRY_RUN" != "true" ]; then
      wait_for_bootscript "${macs[$idx]}" "${xnames[$idx]}"
    fi
  done

  for idx in "${!domain_names[@]}"; do
    disk_path="${VM_DISK_DIR}/${domain_names[$idx]}.qcow2"
    start_darwin_libvirt_domain "${domain_names[$idx]}" "$disk_path" "${macs[$idx]}"
    if [ "$DRY_RUN" != "true" ]; then
      wait_for_darwin_libvirt_console "${domain_names[$idx]}"
    fi
  done

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would finish with ${COUNT} OpenCHAMI test VMs"
  else
    log_info "OpenCHAMI test VMs are defined, registered, and started"
    log_info "VM manifest written to ${MANIFEST_FILE}"
    log_info "libvirt session serial logs are under ${LAB_VM_COMPUTE_LOG_DIR}"
  fi
}

ensure_lab_vm_controller_domain() {
  if [ "$METHOD" != "lab-vm" ]; then
    return 0
  fi

  if libvirt_virsh dominfo "$LAB_VM_CONTROLLER_DOMAIN" >/dev/null 2>&1; then
    return 0
  fi

  log_error "controller VM domain $LAB_VM_CONTROLLER_DOMAIN is not defined on $LIBVIRT_URI"
  log_error "run 'make deploy METHOD=lab-vm' first"
  exit 1
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

  case "$METHOD" in
    compose)
      ensure_libvirt_network "$NETWORK_NAME" "$NETWORK_BRIDGE" "$HOST_IP" "$PXE_CIDR"
      ensure_bridge_carrier "$NETWORK_BRIDGE"
      refresh_compose_kea
      ensure_bss_defaults
      ;;
    lab-vm)
      ;;
  esac
}

register_nodes() {
  SMD_HOST="$SMD_HOST" SMD_PORT="$SMD_PORT" \
    "$SCRIPT_DIR/register-nodes.sh" --nodes-csv "$registration_csv" $DRY_RUN_FLAG
}

reconcile_dhcp_runtime() {
  case "$METHOD" in
    compose)
      trigger_kea_sync
      ;;
    lab-vm)
      ;;
  esac
}

prepare_runtime
if lab_vm_uses_darwin_libvirt_boot_assets; then
  run_darwin_libvirt_lab_vms
  exit 0
fi

ensure_lab_vm_controller_domain

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

register_nodes
reconcile_dhcp_runtime

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
