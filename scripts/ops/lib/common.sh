#!/usr/bin/env bash
# common.sh — Shared functions for OpenCHAMI operational scripts.
# Source this file: . "$(dirname "$0")/lib/common.sh"

set -euo pipefail

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
    log_warn "PXE interface $bridge_name not found; skipping bridge carrier setup"
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
      *)
        shift
        ;;
    esac
  done
}
