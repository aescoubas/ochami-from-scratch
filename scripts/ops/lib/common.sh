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

# wait_for_url URL [MAX_ATTEMPTS] [INTERVAL_SECONDS]
# Returns 0 on success, 1 on timeout.
wait_for_url() {
  local url="$1"
  local max_attempts="${2:-60}"
  local interval="${3:-5}"
  local attempt=1

  log_info "waiting for $url (max ${max_attempts} attempts, ${interval}s interval)"
  while [ "$attempt" -le "$max_attempts" ]; do
    if curl -sf --max-time 5 "$url" >/dev/null 2>&1; then
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
