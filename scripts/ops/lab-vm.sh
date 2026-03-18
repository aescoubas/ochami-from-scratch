#!/usr/bin/env bash
# lab-vm.sh — Start/stop/status/health for the standalone controller VM lab.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"
NIX_FLAKE_REF="${OPENCHAMI_NIX_FLAKE_REF:-$(nix_flake_ref "$PROJECT_ROOT")}"

ACTION="status"

while [ $# -gt 0 ]; do
  case "$1" in
    start|stop|status|health)
      ACTION="$1"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

DEFAULT_LAB_VM_STATE_DIR="${PROJECT_ROOT}/.tmp/lab-vm"
if [ "$(uname -s)" = "Linux" ]; then
  DEFAULT_LAB_VM_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/openchami/lab-vm"
fi

LAB_VM_STATE_DIR="${LAB_VM_STATE_DIR:-${DEFAULT_LAB_VM_STATE_DIR}}"
LAB_VM_TMP_DIR="${LAB_VM_TMP_DIR:-${LAB_VM_STATE_DIR}/tmp}"
LAB_VM_CONTROLLER_HTTP_PORT="${LAB_VM_CONTROLLER_HTTP_PORT:-28000}"
LAB_VM_CONTROLLER_SSH_PORT="${LAB_VM_CONTROLLER_SSH_PORT:-10022}"
LAB_VM_CONTROLLER_BSS_PORT="${LAB_VM_CONTROLLER_BSS_PORT:-29778}"
LAB_VM_CONTROLLER_KEA_CTRL_PORT="${LAB_VM_CONTROLLER_KEA_CTRL_PORT:-28800}"
LAB_VM_CONTROLLER_SMD_PORT="${LAB_VM_CONTROLLER_SMD_PORT:-29779}"
LAB_VM_CONTROLLER_PID_FILE="${LAB_VM_STATE_DIR}/controller.pid"
LAB_VM_CONTROLLER_QEMU_PID_FILE="${LAB_VM_STATE_DIR}/controller.qemu.pid"
LAB_VM_CONTROLLER_LOG="${LAB_VM_STATE_DIR}/controller.log"
LAB_VM_CONTROLLER_SERIAL_LOG="${LAB_VM_STATE_DIR}/controller.serial.log"
DEFAULT_LAB_VM_CONTROLLER_DISK_SIZE="8192M"
DEFAULT_LAB_VM_HEALTH_ATTEMPTS="60"
if [ "$(uname -s)" = "Darwin" ]; then
  DEFAULT_LAB_VM_CONTROLLER_DISK_SIZE="24576M"
  DEFAULT_LAB_VM_HEALTH_ATTEMPTS="180"
fi
LAB_VM_CONTROLLER_DISK="${LAB_VM_CONTROLLER_DISK:-${LAB_VM_STATE_DIR}/openchami-controller.qcow2}"
LAB_VM_HEALTH_ATTEMPTS="${LAB_VM_HEALTH_ATTEMPTS:-${DEFAULT_LAB_VM_HEALTH_ATTEMPTS}}"
LAB_VM_HEALTH_INTERVAL="${LAB_VM_HEALTH_INTERVAL:-2}"
LAB_VM_HTTP_URL="http://127.0.0.1:${LAB_VM_CONTROLLER_HTTP_PORT}/boot.ipxe"
LAB_VM_BUILD_HOST="${OPENCHAMI_LAB_VM_BUILD_HOST:-}"
LAB_VM_BUILD_REPO_PATH="${OPENCHAMI_LAB_VM_BUILD_REPO_PATH:-${PROJECT_ROOT}}"
LAB_VM_BUILD_SSH_OPTS="${OPENCHAMI_LAB_VM_BUILD_SSH_OPTS:-}"
LAB_VM_LIBVIRT_URI="${LAB_VM_LIBVIRT_URI:-$(default_lab_vm_libvirt_uri)}"
LAB_VM_CONTROLLER_DOMAIN="${LAB_VM_CONTROLLER_DOMAIN:-openchami-controller}"
LAB_VM_CONTROLLER_XML="${LAB_VM_STATE_DIR}/controller.xml"
LAB_VM_NETWORK_NAME="${LAB_VM_NETWORK_NAME:-openchami-lab-net}"
LAB_VM_NETWORK_BRIDGE="${LAB_VM_NETWORK_BRIDGE:-virbr-ochlab}"
LAB_VM_NETWORK_XML="${LAB_VM_STATE_DIR}/network.xml"
LAB_VM_CONTROLLER_SHARED_DIR="${LAB_VM_CONTROLLER_SHARED_DIR:-${LAB_VM_STATE_DIR}/shared}"
LAB_VM_CONTROLLER_XCHG_DIR="${LAB_VM_CONTROLLER_XCHG_DIR:-${LAB_VM_STATE_DIR}/xchg}"
LAB_VM_CONTROLLER_MEMORY_MIB="${LAB_VM_CONTROLLER_MEMORY_MIB:-2048}"
LAB_VM_CONTROLLER_VCPUS="${LAB_VM_CONTROLLER_VCPUS:-1}"
LAB_VM_CONTROLLER_DISK_SIZE="${LAB_VM_CONTROLLER_DISK_SIZE:-${DEFAULT_LAB_VM_CONTROLLER_DISK_SIZE}}"
LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_VERSION="${LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_VERSION:-2}"
LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_FILE="${LAB_VM_STATE_DIR}/controller.direct-disk-layout"
LAB_VM_SHARED_NET_MCAST="${LAB_VM_SHARED_NET_MCAST:-230.0.0.1:31337}"
LAB_VM_CONTROLLER_PXE_MAC="${LAB_VM_CONTROLLER_PXE_MAC:-52:54:00:ca:10:01}"
LAB_VM_COMPUTE_STATE_DIR="${LAB_VM_COMPUTE_STATE_DIR:-${LAB_VM_STATE_DIR}/compute}"
LAB_VM_COMPUTE_PID_DIR="${LAB_VM_COMPUTE_PID_DIR:-${LAB_VM_COMPUTE_STATE_DIR}/pids}"
LAB_VM_COMPUTE_LOG_DIR="${LAB_VM_COMPUTE_LOG_DIR:-${LAB_VM_COMPUTE_STATE_DIR}/logs}"
LAB_VM_HOST_QEMU_BIN="${LAB_VM_HOST_QEMU_BIN:-}"
LAB_VM_HOST_QEMU_IMG_BIN="${LAB_VM_HOST_QEMU_IMG_BIN:-}"
LAB_VM_HOST_MKFS_EXT4_BIN="${LAB_VM_HOST_MKFS_EXT4_BIN:-}"

lab_vm_uses_libvirt() {
  case "$(uname -s)" in
    Linux|Darwin)
      return 0
      ;;
  esac

  return 1
}

lab_vm_uses_managed_network() {
  [ "$(uname -s)" = "Linux" ]
}

controller_vm_artifact() {
  nix build "${NIX_FLAKE_REF}#lab-controller-vm" --no-link --print-out-paths
}

controller_vm_guest_system_artifact() {
  nix build "${NIX_FLAKE_REF}#lab-controller-system" --no-link --print-out-paths
}

controller_vm_runner() {
  local vm_out="$1"
  printf '%s/bin/run-openchami-controller-vm\n' "$vm_out"
}

controller_vm_domain_type() {
  if [ "$(uname -s)" = "Linux" ] && [ -e /dev/kvm ]; then
    printf 'kvm\n'
    return 0
  fi

  printf 'qemu\n'
}

remote_lab_vm_ssh() {
  # shellcheck disable=SC2086
  ssh ${LAB_VM_BUILD_SSH_OPTS:-} "$LAB_VM_BUILD_HOST" 'bash -s'
}

copy_store_paths_from_build_host() {
  local remote_store_url="$1"
  local current_nix_sshopts current_nix_config

  current_nix_sshopts="$(printf '%s' "${LAB_VM_BUILD_SSH_OPTS:-${NIX_SSHOPTS:-}}" | sed "s#~/#$HOME/#g")"
  current_nix_config="${NIX_CONFIG:-experimental-features = nix-command flakes}"

  if [ "$(uname -s)" = "Darwin" ] && [ "$(id -u)" -ne 0 ]; then
    if ! sudo -n true >/dev/null 2>&1; then
      log_error "passwordless sudo is required on macOS to import lab-vm store paths from $LAB_VM_BUILD_HOST"
      return 1
    fi

    sudo -n env PATH="$PATH" HOME=/var/root NIX_CONFIG="$current_nix_config" \
      NIX_SSHOPTS="$current_nix_sshopts" \
      nix copy --no-check-sigs --stdin --from "$remote_store_url"
    return $?
  fi

  NIX_SSHOPTS="$current_nix_sshopts" \
    nix copy --no-check-sigs --stdin --from "$remote_store_url"
}

warm_controller_vm_guest_closure_from_build_host() {
  local remote_guest_target remote_guest_target_quoted remote_store_url

  if [ -z "$LAB_VM_BUILD_HOST" ]; then
    return 1
  fi

  remote_guest_target="path:${LAB_VM_BUILD_REPO_PATH}#lab-controller-system"
  remote_guest_target_quoted="$(printf '%q' "$remote_guest_target")"
  remote_store_url="$(nix_ssh_store_url "$LAB_VM_BUILD_HOST")"

  log_info "warming controller VM guest closure from remote Linux build host $LAB_VM_BUILD_HOST"
  if ! remote_lab_vm_ssh <<EOF | copy_store_paths_from_build_host "$remote_store_url"
set -euo pipefail
export NIX_CONFIG='experimental-features = nix-command flakes'
nix build $remote_guest_target_quoted --no-link >/dev/null
nix path-info -r $remote_guest_target_quoted
EOF
  then
    log_error "failed to warm controller VM guest closure from $LAB_VM_BUILD_HOST"
    return 1
  fi

  log_info "controller VM guest closure copied from $LAB_VM_BUILD_HOST"
}

lab_vm_libvirt_virsh() {
  if virsh --connect "$LAB_VM_LIBVIRT_URI" uri >/dev/null 2>&1; then
    virsh --connect "$LAB_VM_LIBVIRT_URI" "$@"
    return $?
  fi

  local sudo_cmd
  sudo_cmd="$(_sudo_noninteractive_cmd)"
  # shellcheck disable=SC2086
  $sudo_cmd virsh --connect "$LAB_VM_LIBVIRT_URI" "$@"
}

lab_vm_network_exists() {
  lab_vm_libvirt_virsh net-info "$LAB_VM_NETWORK_NAME" >/dev/null 2>&1
}

lab_vm_network_is_active() {
  lab_vm_libvirt_virsh net-info "$LAB_VM_NETWORK_NAME" 2>/dev/null \
    | awk -F: '/^Active:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' \
    | grep -qx 'yes'
}

lab_vm_network_bridge_name() {
  lab_vm_libvirt_virsh net-dumpxml "$LAB_VM_NETWORK_NAME" 2>/dev/null \
    | awk -F"'" '/<bridge name=/{print $2; exit}'
}

render_lab_vm_network_xml() {
  cat >"$LAB_VM_NETWORK_XML" <<EOF
<network>
  <name>$(printf '%s' "$LAB_VM_NETWORK_NAME" | xml_escape)</name>
  <bridge name='$(printf '%s' "$LAB_VM_NETWORK_BRIDGE" | xml_escape)' stp='on' delay='0'/>
</network>
EOF
}

ensure_lab_vm_network() {
  local actual_bridge

  if ! lab_vm_uses_managed_network; then
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would ensure lab-vm network $LAB_VM_NETWORK_NAME on bridge $LAB_VM_NETWORK_BRIDGE"
    return 0
  fi

  ensure_controller_vm_dirs
  render_lab_vm_network_xml

  if lab_vm_network_exists; then
    actual_bridge="$(lab_vm_network_bridge_name || true)"
    if [ -n "$actual_bridge" ] && [ "$actual_bridge" != "$LAB_VM_NETWORK_BRIDGE" ]; then
      log_info "redefining lab-vm network $LAB_VM_NETWORK_NAME for bridge $LAB_VM_NETWORK_BRIDGE (was $actual_bridge)"
      if lab_vm_network_is_active; then
        lab_vm_libvirt_virsh net-destroy "$LAB_VM_NETWORK_NAME" >/dev/null 2>&1 || true
      fi
      lab_vm_libvirt_virsh net-undefine "$LAB_VM_NETWORK_NAME" >/dev/null 2>&1 || true
    fi
  fi

  if ! lab_vm_network_exists; then
    log_info "defining lab-vm network $LAB_VM_NETWORK_NAME on bridge $LAB_VM_NETWORK_BRIDGE"
    lab_vm_libvirt_virsh net-define "$LAB_VM_NETWORK_XML" >/dev/null
    lab_vm_libvirt_virsh net-autostart "$LAB_VM_NETWORK_NAME" >/dev/null 2>&1 || true
  fi

  if ! lab_vm_network_is_active; then
    log_info "starting lab-vm network $LAB_VM_NETWORK_NAME"
    lab_vm_libvirt_virsh net-start "$LAB_VM_NETWORK_NAME" >/dev/null
  fi
}

controller_vm_domain_exists() {
  lab_vm_libvirt_virsh dominfo "$LAB_VM_CONTROLLER_DOMAIN" >/dev/null 2>&1
}

controller_vm_domain_state() {
  lab_vm_libvirt_virsh domstate "$LAB_VM_CONTROLLER_DOMAIN" 2>/dev/null | tr -d '\r' | xargs
}

controller_vm_domain_is_running() {
  [ "$(controller_vm_domain_state 2>/dev/null || true)" = "running" ]
}

legacy_controller_vm_is_running() {
  local pid_file pid

  for pid_file in "$LAB_VM_CONTROLLER_QEMU_PID_FILE" "$LAB_VM_CONTROLLER_PID_FILE"; do
    if [ ! -f "$pid_file" ]; then
      continue
    fi

    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

legacy_controller_vm_pid() {
  if [ ! -f "$LAB_VM_CONTROLLER_PID_FILE" ]; then
    if [ -f "$LAB_VM_CONTROLLER_QEMU_PID_FILE" ]; then
      cat "$LAB_VM_CONTROLLER_QEMU_PID_FILE" 2>/dev/null || true
      return 0
    fi
    return 1
  fi

  cat "$LAB_VM_CONTROLLER_QEMU_PID_FILE" "$LAB_VM_CONTROLLER_PID_FILE" 2>/dev/null | awk 'NF { print; exit }'
}

controller_vm_is_running() {
  if lab_vm_uses_libvirt; then
    controller_vm_domain_is_running
    return $?
  fi

  legacy_controller_vm_is_running
}

controller_vm_pid() {
  legacy_controller_vm_pid
}

controller_vm_system_field() {
  local field="$1"
  local system_out="$2"
  jq -re --arg field "$field" '.["org.nixos.bootspec.v1"][$field]' "$system_out/boot.json"
}

controller_vm_registration_info_path() {
  local vm_out="$1"
  local runner="$2"

  if [ ! -x "$runner" ]; then
    return 0
  fi

  grep -o 'regInfo=[^ $"]*' "$runner" 2>/dev/null | head -n 1 | cut -d= -f2-
}

controller_vm_kernel_cmdline() {
  local system_out="$1"
  local reg_info="$2"
  local kernel_params init

  kernel_params="$(jq -r '.["org.nixos.bootspec.v1"].kernelParams | join(" ")' "$system_out/boot.json")"
  init="$(controller_vm_system_field init "$system_out")"

  printf '%s init=%s' "$kernel_params" "$init"
  if [ -n "$reg_info" ]; then
    printf ' regInfo=%s' "$reg_info"
  fi
  printf ' console=ttyS0,115200n8 console=tty0'
}

ensure_controller_vm_dirs() {
  mkdir -p \
    "$LAB_VM_STATE_DIR" \
    "$LAB_VM_TMP_DIR" \
    "$LAB_VM_COMPUTE_STATE_DIR" \
    "$LAB_VM_COMPUTE_PID_DIR" \
    "$LAB_VM_COMPUTE_LOG_DIR" \
    "$LAB_VM_CONTROLLER_SHARED_DIR" \
    "$LAB_VM_CONTROLLER_XCHG_DIR"
}

reconcile_direct_controller_vm_disk_layout() {
  local current_layout=""

  if lab_vm_uses_libvirt; then
    return 0
  fi

  ensure_controller_vm_dirs

  if [ -f "$LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_FILE" ]; then
    current_layout="$(cat "$LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_FILE" 2>/dev/null || true)"
  fi

  if [ -f "$LAB_VM_CONTROLLER_DISK" ] && [ "$current_layout" != "$LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_VERSION" ]; then
    log_info "removing stale direct-QEMU controller disk $LAB_VM_CONTROLLER_DISK to apply disk layout v${LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_VERSION}"
    if [ "$DRY_RUN" = "true" ]; then
      log_info "[dry-run] would remove $LAB_VM_CONTROLLER_DISK and refresh ${LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_FILE}"
      return 0
    fi
    rm -f "$LAB_VM_CONTROLLER_DISK"
  fi

  if [ "$DRY_RUN" != "true" ]; then
    printf '%s\n' "$LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_VERSION" >"$LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_FILE"
  fi
}

stop_direct_compute_vms() {
  local pid_file pid attempt state_found="false"

  if [ ! -d "$LAB_VM_COMPUTE_PID_DIR" ]; then
    return 0
  fi

  for pid_file in "$LAB_VM_COMPUTE_PID_DIR"/*.pid; do
    if [ ! -e "$pid_file" ]; then
      continue
    fi

    state_found="true"
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -z "$pid" ] || ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$pid_file"
      continue
    fi

    if [ "$DRY_RUN" = "true" ]; then
      log_info "[dry-run] would stop direct-QEMU compute VM pid=$pid ($(basename "$pid_file" .pid))"
      continue
    fi

    log_info "stopping direct-QEMU compute VM pid=$pid ($(basename "$pid_file" .pid))"
    kill "$pid" >/dev/null 2>&1 || true
    for attempt in $(seq 1 15); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      log_warn "direct-QEMU compute VM pid=$pid did not stop after 15s; sending SIGKILL"
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file"
  done

  if [ "$state_found" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    find "$LAB_VM_COMPUTE_PID_DIR" -type f -name '*.pid' -delete >/dev/null 2>&1 || true
  fi
}

ensure_controller_vm_disk() {
  local temp_disk qemu_img_bin mkfs_ext4_bin

  if [ -f "$LAB_VM_CONTROLLER_DISK" ]; then
    return 0
  fi

  ensure_controller_vm_dirs

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would create controller VM disk $LAB_VM_CONTROLLER_DISK (${LAB_VM_CONTROLLER_DISK_SIZE})"
    return 0
  fi

  temp_disk="$(mktemp "${LAB_VM_TMP_DIR}/controller-disk.XXXXXX")"
  trap 'rm -f "$temp_disk"' RETURN

  qemu_img_bin="${LAB_VM_HOST_QEMU_IMG_BIN:-$(command -v qemu-img 2>/dev/null || true)}"
  mkfs_ext4_bin="${LAB_VM_HOST_MKFS_EXT4_BIN:-$(command -v mkfs.ext4 2>/dev/null || true)}"
  if [ -z "$qemu_img_bin" ] || [ -z "$mkfs_ext4_bin" ]; then
    log_error "failed to resolve qemu-img or mkfs.ext4 for controller VM disk creation"
    return 1
  fi

  log_info "creating controller VM disk $LAB_VM_CONTROLLER_DISK (${LAB_VM_CONTROLLER_DISK_SIZE})"
  "$qemu_img_bin" create -f raw "$temp_disk" "$LAB_VM_CONTROLLER_DISK_SIZE" >/dev/null
  "$mkfs_ext4_bin" -L nixos "$temp_disk" >/dev/null
  "$qemu_img_bin" convert -f raw -O qcow2 "$temp_disk" "$LAB_VM_CONTROLLER_DISK" >/dev/null

  rm -f "$temp_disk"
  trap - RETURN
}

resolve_controller_vm_host_qemu_tools() {
  local vm_out="$1"
  local runner qemu_bin qemu_img_bin mkfs_ext4_bin

  runner="$(controller_vm_runner "$vm_out")"
  qemu_bin="${LAB_VM_HOST_QEMU_BIN:-}"
  qemu_img_bin="${LAB_VM_HOST_QEMU_IMG_BIN:-}"
  mkfs_ext4_bin="${LAB_VM_HOST_MKFS_EXT4_BIN:-}"

  if [ -x "$runner" ]; then
    if [ -z "$qemu_bin" ]; then
      qemu_bin="$(qemu_system_bin_from_vm_runner "$runner")"
    fi
    if [ -z "$qemu_img_bin" ]; then
      qemu_img_bin="$(qemu_img_bin_from_vm_runner "$runner")"
    fi
    if [ -z "$mkfs_ext4_bin" ]; then
      mkfs_ext4_bin="$(mkfs_ext4_bin_from_vm_runner "$runner")"
    fi
  fi

  if [ -z "$qemu_bin" ] && command_exists qemu-system-x86_64; then
    qemu_bin="$(command -v qemu-system-x86_64)"
  fi
  if [ -z "$qemu_img_bin" ] && command_exists qemu-img; then
    qemu_img_bin="$(command -v qemu-img)"
  fi
  if [ -z "$mkfs_ext4_bin" ] && command_exists mkfs.ext4; then
    mkfs_ext4_bin="$(command -v mkfs.ext4)"
  fi

  LAB_VM_HOST_QEMU_BIN="$qemu_bin"
  LAB_VM_HOST_QEMU_IMG_BIN="$qemu_img_bin"
  LAB_VM_HOST_MKFS_EXT4_BIN="$mkfs_ext4_bin"

  if [ -z "$LAB_VM_HOST_QEMU_BIN" ]; then
    log_error "failed to resolve qemu-system-x86_64 for controller VM domains"
    return 1
  fi

  if [ -z "$LAB_VM_HOST_QEMU_IMG_BIN" ] || [ -z "$LAB_VM_HOST_MKFS_EXT4_BIN" ]; then
    log_error "failed to resolve qemu-img or mkfs.ext4 from the controller VM runner"
    return 1
  fi
}

controller_vm_cpu_xml() {
  if [ "$(uname -s)" = "Linux" ]; then
    cat <<'EOF'
  <cpu mode='host-model'/>
EOF
  fi
}

controller_vm_emulator_xml() {
  if [ -z "${LAB_VM_HOST_QEMU_BIN:-}" ]; then
    return 0
  fi

  cat <<EOF
    <emulator>$(printf '%s' "$LAB_VM_HOST_QEMU_BIN" | xml_escape)</emulator>
EOF
}

controller_vm_domain_namespace() {
  if ! lab_vm_uses_managed_network; then
    printf " xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'"
  fi
}

controller_vm_interface_xml() {
  if lab_vm_uses_managed_network; then
    cat <<EOF
    <interface type='user'>
      <backend type='passt'/>
      <model type='virtio'/>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$LAB_VM_CONTROLLER_HTTP_PORT" | xml_escape)' to='80'/>
      </portForward>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$LAB_VM_CONTROLLER_SSH_PORT" | xml_escape)' to='22'/>
      </portForward>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$LAB_VM_CONTROLLER_BSS_PORT" | xml_escape)' to='27778'/>
      </portForward>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$LAB_VM_CONTROLLER_KEA_CTRL_PORT" | xml_escape)' to='8000'/>
      </portForward>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$LAB_VM_CONTROLLER_SMD_PORT" | xml_escape)' to='27779'/>
      </portForward>
    </interface>
    <interface type='network'>
      <source network='$(printf '%s' "$LAB_VM_NETWORK_NAME" | xml_escape)'/>
      <model type='virtio'/>
    </interface>
EOF
    return 0
  fi

  return 0
}

controller_vm_qemu_commandline_xml() {
  if lab_vm_uses_managed_network; then
    return 0
  fi

  cat <<EOF
  <qemu:commandline>
    <qemu:arg value='-netdev'/>
    <qemu:arg value='user,id=mgmt.0,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_BSS_PORT}-:27778,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_KEA_CTRL_PORT}-:8000,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_SMD_PORT}-:27779'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='virtio-net-pci,netdev=mgmt.0,addr=0xa'/>
    <qemu:arg value='-netdev'/>
    <qemu:arg value='user,id=pxe.0'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='virtio-net-pci,netdev=pxe.0,mac=${LAB_VM_CONTROLLER_PXE_MAC},addr=0xb'/>
  </qemu:commandline>
EOF
}

render_controller_vm_libvirt_xml() {
  local system_out="$1"
  local vm_out="$2"
  local runner kernel initrd cmdline reg_info domain_type

  runner="$(controller_vm_runner "$vm_out")"
  kernel="$(controller_vm_system_field kernel "$system_out")"
  initrd="$(controller_vm_system_field initrd "$system_out")"
  reg_info="$(controller_vm_registration_info_path "$vm_out" "$runner")"
  cmdline="$(controller_vm_kernel_cmdline "$system_out" "$reg_info")"
  domain_type="$(controller_vm_domain_type)"

  cat >"$LAB_VM_CONTROLLER_XML" <<EOF
<domain type='${domain_type}'$(controller_vm_domain_namespace)>
  <name>$(printf '%s' "$LAB_VM_CONTROLLER_DOMAIN" | xml_escape)</name>
  <memory unit='MiB'>$(printf '%s' "$LAB_VM_CONTROLLER_MEMORY_MIB" | xml_escape)</memory>
  <vcpu>$(printf '%s' "$LAB_VM_CONTROLLER_VCPUS" | xml_escape)</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
    <kernel>$(printf '%s' "$kernel" | xml_escape)</kernel>
    <initrd>$(printf '%s' "$initrd" | xml_escape)</initrd>
    <cmdline>$(printf '%s' "$cmdline" | xml_escape)</cmdline>
  </os>
  <features>
    <acpi/>
  </features>
$(controller_vm_cpu_xml)
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
$(controller_vm_emulator_xml)
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='$(printf '%s' "$LAB_VM_CONTROLLER_DISK" | xml_escape)'/>
      <target dev='vda' bus='virtio'/>
      <serial>root</serial>
    </disk>
    <filesystem type='mount' accessmode='passthrough'>
      <source dir='/nix/store'/>
      <target dir='nix-store'/>
    </filesystem>
    <filesystem type='mount' accessmode='passthrough'>
      <source dir='$(printf '%s' "$LAB_VM_CONTROLLER_SHARED_DIR" | xml_escape)'/>
      <target dir='shared'/>
    </filesystem>
    <filesystem type='mount' accessmode='passthrough'>
      <source dir='$(printf '%s' "$LAB_VM_CONTROLLER_XCHG_DIR" | xml_escape)'/>
      <target dir='xchg'/>
    </filesystem>
$(controller_vm_interface_xml)
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <serial type='pty'>
      <log file='$(printf '%s' "$LAB_VM_CONTROLLER_SERIAL_LOG" | xml_escape)' append='off'/>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
$(controller_vm_qemu_commandline_xml)
</domain>
EOF
}

start_controller_vm_process() {
  local runner="$1"

  if command_exists setsid; then
    setsid "$runner" >"$LAB_VM_CONTROLLER_LOG" 2>&1 < /dev/null &
    return 0
  fi

  nohup "$runner" >"$LAB_VM_CONTROLLER_LOG" 2>&1 < /dev/null &
}

stop_legacy_controller_vm() {
  local pid attempt

  if ! legacy_controller_vm_is_running; then
    rm -f "$LAB_VM_CONTROLLER_PID_FILE" "$LAB_VM_CONTROLLER_QEMU_PID_FILE"
    return 0
  fi

  pid="$(legacy_controller_vm_pid)"
  if [ -z "$pid" ]; then
    rm -f "$LAB_VM_CONTROLLER_PID_FILE" "$LAB_VM_CONTROLLER_QEMU_PID_FILE"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would stop legacy controller VM pid=$pid"
    return 0
  fi

  log_info "stopping legacy controller VM pid=$pid"
  kill "$pid" >/dev/null 2>&1 || true
  for attempt in $(seq 1 15); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      rm -f "$LAB_VM_CONTROLLER_PID_FILE" "$LAB_VM_CONTROLLER_QEMU_PID_FILE"
      return 0
    fi
    sleep 1
  done

  log_warn "legacy controller VM did not stop after 15s; sending SIGKILL"
  kill -9 "$pid" >/dev/null 2>&1 || true
  rm -f "$LAB_VM_CONTROLLER_PID_FILE" "$LAB_VM_CONTROLLER_QEMU_PID_FILE"
}

start_controller_vm_with_libvirt() {
  local system_out vm_out state

  require_command virsh "libvirt management"
  require_command jq "JSON processor"
  if [ "$(uname -s)" = "Linux" ]; then
    require_command qemu-img "disk image creation"
    require_command mkfs.ext4 "ext4 disk formatting"
  fi

  if controller_vm_domain_is_running; then
    log_info "controller VM domain $LAB_VM_CONTROLLER_DOMAIN is already running"
    health_controller_vm
    return $?
  fi

  if legacy_controller_vm_is_running; then
    log_warn "stopping legacy direct-QEMU controller VM before switching to libvirt"
    stop_legacy_controller_vm
  fi

  ensure_controller_vm_dirs
  rm -f "$LAB_VM_CONTROLLER_PID_FILE" "$LAB_VM_CONTROLLER_QEMU_PID_FILE" "$LAB_VM_CONTROLLER_SERIAL_LOG"

  if [ "$(uname -s)" = "Darwin" ] && ! nix_has_linux_builder && [ -n "$LAB_VM_BUILD_HOST" ]; then
    warm_controller_vm_guest_closure_from_build_host
  fi

  log_info "building controller VM runner metadata..."
  if ! vm_out="$(controller_vm_artifact)"; then
    if [ "$(uname -s)" = "Darwin" ] && ! nix_has_linux_builder; then
      if [ -n "$LAB_VM_BUILD_HOST" ]; then
        log_error "controller VM build still failed after warming guest closure from $LAB_VM_BUILD_HOST"
        log_error "check the remote build host settings or finish the build from Linux"
      else
        log_error "macOS lab-vm builds need an x86_64-linux builder, OPENCHAMI_LAB_VM_BUILD_HOST, or a fully cached Linux guest closure"
        log_error "configure a remote Linux build host for this repo, or run the controller VM deploy from Linux"
      fi
    fi
    return 1
  fi
  if [ -z "$vm_out" ] || [ ! -d "$vm_out" ]; then
    log_error "failed to build controller VM artifact"
    return 1
  fi

  if ! resolve_controller_vm_host_qemu_tools "$vm_out"; then
    return 1
  fi

  log_info "building controller VM guest system artifact..."
  system_out="$(controller_vm_guest_system_artifact)"
  if [ -z "$system_out" ] || [ ! -d "$system_out" ]; then
    log_error "failed to build controller VM guest system artifact"
    return 1
  fi

  ensure_controller_vm_disk
  ensure_lab_vm_network
  render_controller_vm_libvirt_xml "$system_out" "$vm_out"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would define controller VM domain $LAB_VM_CONTROLLER_DOMAIN via $LAB_VM_CONTROLLER_XML"
    return 0
  fi

  if controller_vm_domain_exists; then
    state="$(controller_vm_domain_state || true)"
    if [ -n "$state" ]; then
      log_info "undefining existing controller VM domain $LAB_VM_CONTROLLER_DOMAIN (state=$state)"
    fi
    if [ "$state" = "running" ]; then
      lab_vm_libvirt_virsh destroy "$LAB_VM_CONTROLLER_DOMAIN" >/dev/null 2>&1 || true
    fi
    lab_vm_libvirt_virsh undefine "$LAB_VM_CONTROLLER_DOMAIN" >/dev/null 2>&1 || true
  fi

  log_info "defining controller VM domain $LAB_VM_CONTROLLER_DOMAIN on ${LAB_VM_LIBVIRT_URI}"
  lab_vm_libvirt_virsh define "$LAB_VM_CONTROLLER_XML" >/dev/null
  log_info "starting controller VM domain $LAB_VM_CONTROLLER_DOMAIN (http=${LAB_VM_CONTROLLER_HTTP_PORT}, ssh=${LAB_VM_CONTROLLER_SSH_PORT})"
  lab_vm_libvirt_virsh start "$LAB_VM_CONTROLLER_DOMAIN" >/dev/null

  sleep 2
  if ! controller_vm_domain_is_running; then
    log_error "controller VM domain failed to stay running"
    [ -f "$LAB_VM_CONTROLLER_SERIAL_LOG" ] && tail -n 60 "$LAB_VM_CONTROLLER_SERIAL_LOG" >&2
    return 1
  fi

  health_controller_vm
}

start_controller_vm_with_runner() {
  local vm_out runner direct_lab_net_qemu_opts

  if legacy_controller_vm_is_running; then
    log_info "controller VM is already running"
    return 0
  fi

  ensure_controller_vm_dirs
  rm -f "$LAB_VM_CONTROLLER_PID_FILE" "$LAB_VM_CONTROLLER_QEMU_PID_FILE" "$LAB_VM_CONTROLLER_SERIAL_LOG"
  reconcile_direct_controller_vm_disk_layout

  if [ "$(uname -s)" = "Darwin" ] && ! nix_has_linux_builder && [ -n "$LAB_VM_BUILD_HOST" ]; then
    warm_controller_vm_guest_closure_from_build_host
  fi

  log_info "building controller VM artifact..."
  if ! vm_out="$(controller_vm_artifact)"; then
    if [ "$(uname -s)" = "Darwin" ] && ! nix_has_linux_builder; then
      if [ -n "$LAB_VM_BUILD_HOST" ]; then
        log_error "controller VM build still failed after warming guest closure from $LAB_VM_BUILD_HOST"
        log_error "check the remote build host settings or finish the build from Linux"
      else
        log_error "macOS lab-vm builds need an x86_64-linux builder, OPENCHAMI_LAB_VM_BUILD_HOST, or a fully cached Linux guest closure"
        log_error "configure a remote Linux build host for this repo, or run the controller VM deploy from Linux"
      fi
    fi
    return 1
  fi
  if [ -z "$vm_out" ] || [ ! -d "$vm_out" ]; then
    log_error "failed to build controller VM artifact"
    return 1
  fi

  runner="$(controller_vm_runner "$vm_out")"
  if [ ! -x "$runner" ]; then
    log_error "controller VM runner not found: $runner"
    return 1
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would start controller VM via $runner"
    return 0
  fi

  direct_lab_net_qemu_opts=""
  if ! lab_vm_uses_libvirt; then
    direct_lab_net_qemu_opts="-netdev socket,id=lab.0,mcast=${LAB_VM_SHARED_NET_MCAST} -device virtio-net-pci,netdev=lab.0,mac=${LAB_VM_CONTROLLER_PXE_MAC}"
  fi

  log_info "starting controller VM (http=${LAB_VM_CONTROLLER_HTTP_PORT}, ssh=${LAB_VM_CONTROLLER_SSH_PORT})"
  (
    export TMPDIR="$LAB_VM_TMP_DIR"
    export USE_TMPDIR=1
    export NIX_DISK_IMAGE="$LAB_VM_CONTROLLER_DISK"
    export QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_BSS_PORT}-:27778,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_KEA_CTRL_PORT}-:8000,hostfwd=tcp:127.0.0.1:${LAB_VM_CONTROLLER_SMD_PORT}-:27779${LAB_VM_EXTRA_NET_OPTS:+,${LAB_VM_EXTRA_NET_OPTS}}"
    export QEMU_OPTS="-display none -serial file:${LAB_VM_CONTROLLER_SERIAL_LOG} -pidfile ${LAB_VM_CONTROLLER_QEMU_PID_FILE}${direct_lab_net_qemu_opts:+ ${direct_lab_net_qemu_opts}}${LAB_VM_EXTRA_QEMU_OPTS:+ ${LAB_VM_EXTRA_QEMU_OPTS}}"
    start_controller_vm_process "$runner"
    echo $! >"$LAB_VM_CONTROLLER_PID_FILE"
  )

  sleep 2
  if ! legacy_controller_vm_is_running; then
    if grep -q "Could not set up host forwarding rule" "$LAB_VM_CONTROLLER_LOG" 2>/dev/null; then
      log_error "controller VM failed to bind forwarded host ports ${LAB_VM_CONTROLLER_HTTP_PORT} or ${LAB_VM_CONTROLLER_SSH_PORT}"
    fi
    log_error "controller VM failed to stay running"
    [ -f "$LAB_VM_CONTROLLER_LOG" ] && tail -n 40 "$LAB_VM_CONTROLLER_LOG" >&2
    return 1
  fi

  health_controller_vm
}

start_controller_vm() {
  if lab_vm_uses_libvirt; then
    start_controller_vm_with_libvirt
    return $?
  fi

  start_controller_vm_with_runner
}

health_controller_vm() {
  local bss_url smd_url

  log_info "checking controller VM boot artifacts at ${LAB_VM_HTTP_URL}"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would check ${LAB_VM_HTTP_URL}"
    return 0
  fi

  if ! controller_vm_is_running; then
    log_error "controller VM is not running"
    return 1
  fi

  if ! wait_for_url "$LAB_VM_HTTP_URL" "$LAB_VM_HEALTH_ATTEMPTS" "$LAB_VM_HEALTH_INTERVAL"; then
    [ -f "$LAB_VM_CONTROLLER_SERIAL_LOG" ] && tail -n 60 "$LAB_VM_CONTROLLER_SERIAL_LOG" >&2
    return 1
  fi

  if curl -fsS "$LAB_VM_HTTP_URL" | grep -q '^#!ipxe'; then
    bss_url="http://127.0.0.1:${LAB_VM_CONTROLLER_BSS_PORT}/boot/v1/bootparameters"
    smd_url="https://127.0.0.1:${LAB_VM_CONTROLLER_SMD_PORT}/hsm/v2/service/ready"

    if ! wait_for_url "$bss_url" "$LAB_VM_HEALTH_ATTEMPTS" "$LAB_VM_HEALTH_INTERVAL"; then
      return 1
    fi

    if ! wait_for_url "$smd_url" "$LAB_VM_HEALTH_ATTEMPTS" "$LAB_VM_HEALTH_INTERVAL" "-k"; then
      return 1
    fi

    if ! ( : >"/dev/tcp/127.0.0.1/${LAB_VM_CONTROLLER_KEA_CTRL_PORT}" ) >/dev/null 2>&1; then
      log_error "controller VM Kea control socket is not reachable on 127.0.0.1:${LAB_VM_CONTROLLER_KEA_CTRL_PORT}"
      return 1
    fi

    log_info "controller VM is healthy"
    return 0
  fi

  log_error "controller VM responded, but boot.ipxe content was unexpected"
  return 1
}

stop_controller_vm_with_libvirt() {
  local state attempt

  if ! controller_vm_domain_exists; then
    log_info "controller VM domain $LAB_VM_CONTROLLER_DOMAIN is not defined"
    return 0
  fi

  state="$(controller_vm_domain_state || true)"
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would stop controller VM domain $LAB_VM_CONTROLLER_DOMAIN (state=${state:-unknown})"
    return 0
  fi

  log_info "stopping controller VM domain $LAB_VM_CONTROLLER_DOMAIN (state=${state:-unknown})"
  if [ "$state" = "running" ]; then
    lab_vm_libvirt_virsh destroy "$LAB_VM_CONTROLLER_DOMAIN" >/dev/null 2>&1 || true
  fi

  for attempt in $(seq 1 15); do
    state="$(controller_vm_domain_state || true)"
    if [ "$state" != "running" ]; then
      break
    fi
    sleep 1
  done

  lab_vm_libvirt_virsh undefine "$LAB_VM_CONTROLLER_DOMAIN" >/dev/null 2>&1 || true
  rm -f "$LAB_VM_CONTROLLER_XML"
  log_info "controller VM domain stopped"
}

stop_controller_vm() {
  if lab_vm_uses_libvirt; then
    stop_controller_vm_with_libvirt
    stop_direct_compute_vms
    stop_legacy_controller_vm
    return 0
  fi

  stop_direct_compute_vms
  stop_legacy_controller_vm
  if ! legacy_controller_vm_is_running; then
    log_info "controller VM is not running"
    return 0
  fi
}

status_controller_vm() {
  local state

  if lab_vm_uses_libvirt; then
    if controller_vm_domain_exists; then
      state="$(controller_vm_domain_state || true)"
      log_info "controller VM domain $LAB_VM_CONTROLLER_DOMAIN is ${state:-unknown} via ${LAB_VM_LIBVIRT_URI}"
      if [ "${state:-}" = "running" ]; then
        log_info "controller VM endpoints: ${LAB_VM_HTTP_URL}, ssh://lab@127.0.0.1:${LAB_VM_CONTROLLER_SSH_PORT}, http://127.0.0.1:${LAB_VM_CONTROLLER_BSS_PORT}/boot/v1/bootparameters, tcp://127.0.0.1:${LAB_VM_CONTROLLER_KEA_CTRL_PORT}, and https://127.0.0.1:${LAB_VM_CONTROLLER_SMD_PORT}"
        log_info "inspect with: virsh --connect ${LAB_VM_LIBVIRT_URI} list"
      fi
      return 0
    fi

    if legacy_controller_vm_is_running; then
      log_warn "legacy direct-QEMU controller VM is still running (pid=$(legacy_controller_vm_pid))"
      log_info "controller VM endpoints: ${LAB_VM_HTTP_URL} and ssh://lab@127.0.0.1:${LAB_VM_CONTROLLER_SSH_PORT}"
      return 0
    fi

    log_info "controller VM is stopped"
    return 0
  fi

  if legacy_controller_vm_is_running; then
    log_info "controller VM is running (pid=$(legacy_controller_vm_pid))"
    log_info "controller VM endpoints: ${LAB_VM_HTTP_URL} and ssh://lab@127.0.0.1:${LAB_VM_CONTROLLER_SSH_PORT}"
    log_info "controller VM PXE network: qemu socket multicast ${LAB_VM_SHARED_NET_MCAST} (controller MAC ${LAB_VM_CONTROLLER_PXE_MAC})"
    if [ -d "$LAB_VM_COMPUTE_PID_DIR" ] && find "$LAB_VM_COMPUTE_PID_DIR" -maxdepth 1 -type f -name '*.pid' | grep -q .; then
      log_info "direct-QEMU compute VM pid files: ${LAB_VM_COMPUTE_PID_DIR}"
      log_info "direct-QEMU compute VM serial logs: ${LAB_VM_COMPUTE_LOG_DIR}"
    fi
  else
    log_info "controller VM is stopped"
  fi
}

case "$ACTION" in
  start)
    start_controller_vm
    ;;
  stop)
    stop_controller_vm
    ;;
  status)
    status_controller_vm
    ;;
  health)
    health_controller_vm
    ;;
  *)
    log_error "usage: $0 start|stop|status|health [--dry-run]"
    exit 1
    ;;
esac
