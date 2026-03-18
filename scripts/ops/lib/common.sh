#!/usr/bin/env bash
# common.sh — Shared functions for OpenCHAMI operational scripts.
# Source this file: . "$(dirname "$0")/lib/common.sh"

set -euo pipefail

# --- Host PATH bootstrap ---

bootstrap_host_path() {
  local host_os
  host_os="$(uname -s)"

  if [ "$host_os" != "Darwin" ]; then
    return 0
  fi

  local dir
  local -a path_candidates=(
    "/opt/homebrew/opt/coreutils/libexec/gnubin"
    "/opt/homebrew/opt/gettext/bin"
    "/opt/homebrew/bin"
    "/Applications/Docker.app/Contents/Resources/bin"
    "/nix/var/nix/profiles/default/bin"
    "${HOME}/.nix-profile/bin"
    "/usr/local/opt/coreutils/libexec/gnubin"
    "/usr/local/opt/gettext/bin"
    "/usr/local/bin"
  )

  for dir in "${path_candidates[@]}"; do
    if [ ! -d "$dir" ]; then
      continue
    fi

    case ":$PATH:" in
      *":$dir:"*)
        ;;
      *)
        PATH="$dir:$PATH"
        ;;
    esac
  done

  export PATH
}

bootstrap_host_path

# --- Nix bootstrap ---

ensure_nix_flake_support() {
  case "${NIX_CONFIG:-}" in
    *"nix-command"*flakes*|*"flakes"*nix-command*)
      return 0
      ;;
  esac

  if [ -n "${NIX_CONFIG:-}" ]; then
    NIX_CONFIG="experimental-features = nix-command flakes
${NIX_CONFIG}"
  else
    NIX_CONFIG="experimental-features = nix-command flakes"
  fi

  export NIX_CONFIG
}

ensure_nix_flake_support

nix_flake_ref() {
  local root="${1:-${PROJECT_ROOT:-$PWD}}"
  printf 'path:%s' "$root"
}

nix_ssh_store_url() {
  local target="$1"
  printf 'ssh://%s?trusted=1' "$target"
}

default_lab_vm_libvirt_uri() {
  if [ "$(uname -s)" = "Darwin" ]; then
    printf 'qemu:///session\n'
    return 0
  fi

  printf 'qemu:///system\n'
}

libvirt_uri_is_session() {
  case "$1" in
    *:///session)
      return 0
      ;;
  esac

  return 1
}

nix_has_linux_builder() {
  nix show-config 2>/dev/null | grep -Eq '(^|[[:space:]=])x86_64-linux([[:space:];,]|$)'
}

# --- Logging ---

_log() {
  local level="$1"; shift
  printf '[%s] %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" >&2
}

log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

# --- Dependency checking ---

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  local cmd="$1"
  local purpose="${2:-}"
  if ! command_exists "$cmd"; then
    if [ -n "$purpose" ]; then
      log_error "required command '$cmd' not found ($purpose)"
    else
      log_error "required command '$cmd' not found"
    fi
    return 1
  fi
}

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e "s/'/\&apos;/g" \
    -e 's/"/\&quot;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g'
}

qemu_system_bin_from_vm_runner() {
  local runner="$1"

  sed -n 's#^exec \([^ ]*qemu-system-x86_64\) .*#\1#p' "$runner" | head -n 1
}

qemu_img_bin_from_vm_runner() {
  local runner="$1"
  local qemu_bin

  qemu_bin="$(qemu_system_bin_from_vm_runner "$runner")"
  if [ -z "$qemu_bin" ]; then
    return 1
  fi

  printf '%s/qemu-img\n' "$(dirname "$qemu_bin")"
}

mkfs_ext4_bin_from_vm_runner() {
  local runner="$1"

  sed -n 's#.* \(/[^ ]*mkfs\.ext4\) .*#\1#p' "$runner" | head -n 1
}

docker_compose_available() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    return 0
  fi

  command_exists docker-compose
}

docker_compose_label() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    printf 'docker compose (v2 plugin)'
    return 0
  fi

  if command_exists docker-compose; then
    printf 'docker-compose (v1)'
    return 0
  fi

  return 1
}

docker_daemon_reachable() {
  command_exists docker && docker info >/dev/null 2>&1
}

docker_compose() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    run_cmd docker compose "$@"
    return $?
  fi

  if command_exists docker-compose; then
    run_cmd docker-compose "$@"
    return $?
  fi

  log_error "docker compose is not available"
  return 1
}

# --- HTTP waiting ---

# wait_for_url URL [MAX_ATTEMPTS] [INTERVAL_SECONDS] [CURL_FLAGS]
# Returns 0 on success, 1 on timeout.
wait_for_url() {
  local url="$1"
  local max_attempts="${2:-60}"
  local interval="${3:-5}"
  local curl_flags="${4:-}"
  local attempt=1

  log_info "waiting for $url (max ${max_attempts} attempts, ${interval}s interval)"
  while [ "$attempt" -le "$max_attempts" ]; do
    # shellcheck disable=SC2086
    if curl -sf --max-time 5 $curl_flags "$url" >/dev/null 2>&1; then
      log_info "$url is ready (attempt $attempt)"
      return 0
    fi
    sleep "$interval"
    attempt=$((attempt + 1))
  done

  log_error "$url not ready after $max_attempts attempts"
  return 1
}

# --- Secret generation ---

# generate_secret [LENGTH]
# Generates a random alphanumeric secret.
generate_secret() {
  local length="${1:-32}"
  head -c 256 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# ensure_secrets_file FILE
# Creates a secrets.env file with random passwords if it doesn't exist.
ensure_secrets_file() {
  local secrets_file="$1"
  if [ -f "$secrets_file" ]; then
    log_info "secrets file already exists: $secrets_file"
    return 0
  fi

  log_info "generating secrets file: $secrets_file"
  mkdir -p "$(dirname "$secrets_file")"
  {
    echo "# Auto-generated OpenCHAMI secrets — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "POSTGRES_PASSWORD=$(generate_secret)"
    echo "SMD_DB_PASSWORD=$(generate_secret)"
    echo "BSS_DB_PASSWORD=$(generate_secret)"
    echo "KEA_DB_PASSWORD=$(generate_secret)"
    echo "PCS_DB_PASSWORD=$(generate_secret)"
    echo "STORK_DB_PASSWORD=$(generate_secret)"
  } > "$secrets_file"
  chmod 600 "$secrets_file"
  log_info "secrets file created: $secrets_file"
}

_sudo_noninteractive_cmd() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  if sudo -n true >/dev/null 2>&1; then
    printf 'sudo -n'
    return 0
  fi

  log_error "passwordless sudo is required for PXE bridge preparation"
  return 1
}

cidr_to_netmask() {
  local cidr="$1"
  local full_octets remainder octet idx
  local -a parts=()

  if ! [[ "$cidr" =~ ^[0-9]+$ ]] || [ "$cidr" -lt 0 ] || [ "$cidr" -gt 32 ]; then
    log_error "invalid CIDR prefix: $cidr"
    return 1
  fi

  full_octets=$((cidr / 8))
  remainder=$((cidr % 8))

  for idx in 0 1 2 3; do
    if [ "$idx" -lt "$full_octets" ]; then
      parts+=(255)
    elif [ "$idx" -eq "$full_octets" ] && [ "$remainder" -gt 0 ]; then
      octet=$((256 - 2 ** (8 - remainder)))
      parts+=("$octet")
    else
      parts+=(0)
    fi
  done

  printf '%s.%s.%s.%s\n' "${parts[0]}" "${parts[1]}" "${parts[2]}" "${parts[3]}"
}

libvirt_network_is_active() {
  local network_name="$1"
  sudo -n virsh net-info "$network_name" 2>/dev/null \
    | awk -F: '/^Active:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' \
    | grep -qx 'yes'
}

ensure_libvirt_network() {
  local network_name="$1"
  local bridge_name="$2"
  local gateway_ip="$3"
  local cidr_prefix="${4:-24}"
  local sudo_cmd netmask net_xml actual_bridge actual_ip recreate_network="false"
  local legacy_network_name="${OPENCHAMI_LEGACY_PXE_NETWORK_NAME:-pxe-net}"
  local legacy_bridge_name="${OPENCHAMI_LEGACY_PXE_BRIDGE_NAME:-virbr-pxe}"
  local legacy_bridge legacy_ip

  require_command virsh "libvirt management"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would ensure libvirt network $network_name on $bridge_name (${gateway_ip}/${cidr_prefix})"
    return 0
  fi

  sudo_cmd="$(_sudo_noninteractive_cmd)"
  netmask="$(cidr_to_netmask "$cidr_prefix")"

  if sudo -n virsh net-info "$network_name" >/dev/null 2>&1; then
    actual_bridge="$(sudo -n virsh net-dumpxml "$network_name" | awk -F"'" '/<bridge name=/{print $2; exit}')"
    actual_ip="$(sudo -n virsh net-dumpxml "$network_name" | awk -F"'" '/<ip address=/{print $2; exit}')"

    if [ -n "$actual_bridge" ] && [ "$actual_bridge" != "$bridge_name" ]; then
      if libvirt_network_is_active "$network_name"; then
        log_error "libvirt network $network_name uses bridge $actual_bridge, expected $bridge_name"
        return 1
      fi
      log_info "redefining libvirt network $network_name from bridge $actual_bridge to $bridge_name"
      # shellcheck disable=SC2086
      $sudo_cmd virsh net-undefine "$network_name" >/dev/null || true
      recreate_network="true"
    fi

    if [ -n "$actual_ip" ] && [ "$actual_ip" != "$gateway_ip" ]; then
      if libvirt_network_is_active "$network_name"; then
        log_error "libvirt network $network_name uses gateway $actual_ip, expected $gateway_ip"
        return 1
      fi
      log_info "redefining libvirt network $network_name from gateway $actual_ip to $gateway_ip"
      # shellcheck disable=SC2086
      $sudo_cmd virsh net-undefine "$network_name" >/dev/null || true
      recreate_network="true"
    fi

    if [ "$recreate_network" != "true" ] && ! libvirt_network_is_active "$network_name"; then
      if [ "$network_name" != "$legacy_network_name" ] \
        && sudo -n virsh net-info "$legacy_network_name" >/dev/null 2>&1; then
        legacy_bridge="$(sudo -n virsh net-dumpxml "$legacy_network_name" | awk -F"'" '/<bridge name=/{print $2; exit}')"
        legacy_ip="$(sudo -n virsh net-dumpxml "$legacy_network_name" | awk -F"'" '/<ip address=/{print $2; exit}')"

        if [ "$legacy_bridge" = "$legacy_bridge_name" ] && [ "$legacy_ip" = "$gateway_ip" ]; then
          log_info "retiring legacy libvirt network $legacy_network_name (${legacy_bridge_name}) before starting $network_name"
          if libvirt_network_is_active "$legacy_network_name"; then
            # shellcheck disable=SC2086
            $sudo_cmd virsh net-destroy "$legacy_network_name" >/dev/null
          fi
          # shellcheck disable=SC2086
          $sudo_cmd virsh net-undefine "$legacy_network_name" >/dev/null || true
          if command_exists ip && ip link show "$legacy_bridge_name" >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            $sudo_cmd ip link delete "$legacy_bridge_name" >/dev/null 2>&1 || true
          fi
        fi
      fi
      log_info "starting libvirt network $network_name"
      # shellcheck disable=SC2086
      $sudo_cmd virsh net-start "$network_name" >/dev/null 2>&1 || true
      if ! libvirt_network_is_active "$network_name"; then
        log_error "failed to start libvirt network $network_name"
        return 1
      fi
    fi
    if [ "$recreate_network" != "true" ]; then
      # shellcheck disable=SC2086
      $sudo_cmd virsh net-autostart "$network_name" >/dev/null || true
      log_info "libvirt network $network_name is ready on $bridge_name"
      return 0
    fi
  fi

  if [ "$network_name" != "$legacy_network_name" ] \
    && sudo -n virsh net-info "$legacy_network_name" >/dev/null 2>&1; then
    legacy_bridge="$(sudo -n virsh net-dumpxml "$legacy_network_name" | awk -F"'" '/<bridge name=/{print $2; exit}')"
    legacy_ip="$(sudo -n virsh net-dumpxml "$legacy_network_name" | awk -F"'" '/<ip address=/{print $2; exit}')"

    if [ "$legacy_bridge" = "$legacy_bridge_name" ] && [ "$legacy_ip" = "$gateway_ip" ]; then
      log_info "migrating legacy libvirt network $legacy_network_name (${legacy_bridge_name}) to $network_name (${bridge_name})"
      if libvirt_network_is_active "$legacy_network_name"; then
        # shellcheck disable=SC2086
        $sudo_cmd virsh net-destroy "$legacy_network_name" >/dev/null
      fi
      # shellcheck disable=SC2086
      $sudo_cmd virsh net-undefine "$legacy_network_name" >/dev/null || true
      if command_exists ip && ip link show "$legacy_bridge_name" >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        $sudo_cmd ip link delete "$legacy_bridge_name" >/dev/null 2>&1 || true
      fi
    fi
  fi

  net_xml="$(mktemp)"
  cat > "$net_xml" <<EOF
<network>
  <name>${network_name}</name>
  <bridge name="${bridge_name}" stp="off" delay="0"/>
  <ip address="${gateway_ip}" netmask="${netmask}">
  </ip>
</network>
EOF

  log_info "creating libvirt network $network_name on bridge $bridge_name"
  # shellcheck disable=SC2086
  $sudo_cmd virsh net-define "$net_xml" >/dev/null
  # shellcheck disable=SC2086
  $sudo_cmd virsh net-start "$network_name" >/dev/null
  # shellcheck disable=SC2086
  $sudo_cmd virsh net-autostart "$network_name" >/dev/null
  rm -f "$net_xml"
  log_info "libvirt network $network_name is ready on $bridge_name"
}

ensure_bridge_carrier() {
  local bridge_name="$1"
  local dummy_iface="${2:-${OPENCHAMI_PXE_DUMMY_IFACE:-ochami-pxe0}}"
  local max_attempts="${3:-10}"
  local sudo_cmd
  local attempt=1

  if ! command_exists ip; then
    log_error "required command 'ip' not found (network interface management)"
    return 1
  fi

  if ! ip link show "$bridge_name" >/dev/null 2>&1; then
    log_warn "PXE bridge $bridge_name not found; skipping carrier preparation"
    return 0
  fi

  if ! ip -d link show "$bridge_name" | grep -q " bridge "; then
    return 0
  fi

  if ip -d link show "$bridge_name" | grep -q "LOWER_UP"; then
    log_info "PXE bridge $bridge_name already has carrier"
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would attach dummy interface $dummy_iface to $bridge_name"
    return 0
  fi

  sudo_cmd="$(_sudo_noninteractive_cmd)"
  log_info "attaching dummy interface $dummy_iface to $bridge_name to provide carrier"
  if ! ip link show "$dummy_iface" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    $sudo_cmd ip link add "$dummy_iface" type dummy
  fi
  # shellcheck disable=SC2086
  $sudo_cmd ip link set "$dummy_iface" master "$bridge_name"
  # shellcheck disable=SC2086
  $sudo_cmd ip link set "$dummy_iface" up
  # shellcheck disable=SC2086
  $sudo_cmd ip link set "$bridge_name" up

  while [ "$attempt" -le "$max_attempts" ]; do
    if ip -d link show "$bridge_name" | grep -q "LOWER_UP"; then
      log_info "PXE bridge $bridge_name now has carrier"
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  log_error "PXE bridge $bridge_name still reports no carrier after ${max_attempts}s"
  return 1
}

remove_bridge_carrier_dummy() {
  local dummy_iface="${1:-${OPENCHAMI_PXE_DUMMY_IFACE:-ochami-pxe0}}"
  local sudo_cmd

  if ! command_exists ip; then
    return 0
  fi

  if ! ip link show "$dummy_iface" >/dev/null 2>&1; then
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would remove dummy interface $dummy_iface"
    return 0
  fi

  sudo_cmd="$(_sudo_noninteractive_cmd)"
  log_info "removing dummy interface $dummy_iface"
  # shellcheck disable=SC2086
  $sudo_cmd ip link delete "$dummy_iface"
}

disable_conflicting_dhcp_networks() {
  local target_iface="$1"
  local state_file="$2"
  local sudo_cmd

  if ! command_exists virsh; then
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would stop libvirt DHCP networks that conflict with $target_iface"
    return 0
  fi

  sudo_cmd="$(_sudo_noninteractive_cmd)"
  mkdir -p "$(dirname "$state_file")"
  : > "$state_file"

  while IFS= read -r network_name; do
    [ -n "$network_name" ] || continue
    local conf_path="/var/lib/libvirt/dnsmasq/${network_name}.conf"
    local network_iface=""

    if ! sudo -n test -f "$conf_path"; then
      continue
    fi

    network_iface=$(sudo -n awk -F= '/^interface=/{print $2; exit}' "$conf_path")
    if sudo -n grep -q '^dhcp-range=' "$conf_path" && [ "$network_iface" != "$target_iface" ]; then
      log_info "stopping conflicting libvirt DHCP network $network_name (${network_iface})"
      # shellcheck disable=SC2086
      $sudo_cmd virsh net-destroy "$network_name" >/dev/null
      echo "$network_name" >> "$state_file"
    fi
  done < <(sudo -n virsh net-list --name)

  if [ ! -s "$state_file" ]; then
    rm -f "$state_file"
  fi
}

restore_conflicting_dhcp_networks() {
  local state_file="$1"
  local sudo_cmd

  if [ ! -f "$state_file" ]; then
    return 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would restart libvirt DHCP networks listed in $state_file"
    return 0
  fi

  sudo_cmd="$(_sudo_noninteractive_cmd)"
  while IFS= read -r network_name; do
    [ -n "$network_name" ] || continue
    log_info "restarting libvirt DHCP network $network_name"
    # shellcheck disable=SC2086
    $sudo_cmd virsh net-start "$network_name" >/dev/null || true
  done < "$state_file"
  rm -f "$state_file"
}

# --- Dry-run support ---

DRY_RUN="${DRY_RUN:-false}"
PROFILE="${OPENCHAMI_PROFILE:-official}"

run_cmd() {
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# --- Argument parsing helpers ---

parse_common_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --method)
        METHOD="${2:-}"
        shift 2
        ;;
      --method=*)
        METHOD="${1#--method=}"
        shift
        ;;
      --profile)
        PROFILE="${2:-official}"
        shift 2
        ;;
      --profile=*)
        PROFILE="${1#--profile=}"
        shift
        ;;
      *)
        shift
        ;;
    esac
  done
}

flake_output_for_profile() {
  local base="$1"
  local profile_name="${2:-${PROFILE:-official}}"

  if [ "$profile_name" = "official" ]; then
    printf '%s\n' "$base"
    return 0
  fi

  printf '%s-%s\n' "$base" "$profile_name"
}
