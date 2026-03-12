#!/usr/bin/env bash
# health-check.sh — Wait for OpenCHAMI services to become healthy.
# Usage: ./health-check.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

HOST="${HOST_IP:-localhost}"
HTTP_PORT="${HTTP_PORT:-80}"
SMD_PORT="${SMD_PORT:-27779}"
BSS_PORT="${BSS_PORT:-27778}"
CLOUD_INIT_PORT="${CLOUD_INIT_PORT:-27777}"
PCS_PORT="${PCS_PORT:-28007}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
INTERVAL="${INTERVAL:-5}"

failed=0

check_service() {
  local name="$1"
  local url="$2"
  log_info "checking $name at $url"
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would check $url"
    return 0
  fi
  if wait_for_url "$url" "$MAX_ATTEMPTS" "$INTERVAL"; then
    log_info "$name is healthy"
  else
    log_error "$name is NOT healthy"
    failed=$((failed + 1))
  fi
}

check_service "PostgreSQL" "http://${HOST}:${HTTP_PORT}/hsm/v2/service/ready"
check_service "SMD" "http://${HOST}:${SMD_PORT}/hsm/v2/service/ready"
check_service "BSS" "http://${HOST}:${BSS_PORT}/boot/v1/bootparameters"
check_service "Nginx" "http://${HOST}:${HTTP_PORT}/"
# Cloud-init and PCS don't have simple GET healthchecks; check via port
if [ "$DRY_RUN" != "true" ]; then
  for svc_check in "cloud-init:${CLOUD_INIT_PORT}" "pcs:${PCS_PORT}"; do
    svc_name="${svc_check%%:*}"
    svc_port="${svc_check##*:}"
    log_info "checking $svc_name on port $svc_port"
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${HOST}/${svc_port}" 2>/dev/null; then
      log_info "$svc_name is healthy (port open)"
    else
      log_warn "$svc_name port $svc_port is not open (may not be started yet)"
    fi
  done
fi

if [ "$failed" -gt 0 ]; then
  log_error "$failed service(s) failed health check"
  exit 1
fi

log_info "all services healthy"
