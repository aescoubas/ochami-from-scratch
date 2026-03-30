#!/usr/bin/env bash
# health-check.sh — Wait for OpenCHAMI services to become healthy.
# Usage: ./health-check.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

HOST="${HOST_IP:-localhost}"
HTTP_PORT="${HTTP_PORT:-80}"
SMD_PORT="${SMD_PORT:-27779}"
BSS_PORT="${BSS_PORT:-27778}"
CLOUD_INIT_PORT="${CLOUD_INIT_PORT:-27777}"
PCS_PORT="${PCS_PORT:-28007}"
KEA_PORT="${KEA_PORT:-67}"
KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"
CHECK_KEA="${CHECK_KEA:-false}"
PXE_INTERFACE="${PXE_INTERFACE:-virbr-ochami}"
TEST_NODE_IMAGE="${TEST_NODE_IMAGE:-almalinux}"
TEST_NODE_IMAGE="${OPENCHAMI_TEST_NODE_IMAGE:-$TEST_NODE_IMAGE}"

MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
INTERVAL="${INTERVAL:-5}"

failed=0

BOOT_ARTIFACTS_PATH="${BOOT_ARTIFACTS_PATH:-}"
if [ -z "$BOOT_ARTIFACTS_PATH" ] && [ "$DRY_RUN" != "true" ]; then
  log_info "building boot artifacts for ${TEST_NODE_IMAGE}"
  "$SCRIPT_DIR/build-boot-artifacts.sh"
  BOOT_ARTIFACTS_PATH="${PROJECT_ROOT}/.tmp/boot-artifacts"
fi

if [ "$DRY_RUN" = "true" ]; then
  BOOT_IMAGE_RELATIVE_DIR="artifacts/${TEST_NODE_IMAGE}"
  BOOT_IMAGE_KERNEL_FILE="vmlinuz"
  BOOT_IMAGE_INITRD_FILE="initrd"
else
  resolve_boot_image_metadata "$BOOT_ARTIFACTS_PATH" "$TEST_NODE_IMAGE"
fi

check_service() {
  local name="$1"
  local url="$2"
  local curl_flags="${3:-}"
  log_info "checking $name at $url"
  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] would check $url"
    return 0
  fi
  if wait_for_url "$url" "$MAX_ATTEMPTS" "$INTERVAL" "$curl_flags"; then
    log_info "$name is healthy"
  else
    log_error "$name is NOT healthy"
    failed=$((failed + 1))
  fi
}

check_service "HTTP server" "http://${HOST}:${HTTP_PORT}/"
check_service "Boot kernel" "http://${HOST}:${HTTP_PORT}/${BOOT_IMAGE_RELATIVE_DIR}/${BOOT_IMAGE_KERNEL_FILE}" "-I"
check_service "Boot initramfs" "http://${HOST}:${HTTP_PORT}/${BOOT_IMAGE_RELATIVE_DIR}/${BOOT_IMAGE_INITRD_FILE}" "-I"
check_service "SMD" "https://${HOST}:${SMD_PORT}/hsm/v2/service/ready" "-k"
check_service "BSS" "http://${HOST}:${BSS_PORT}/boot/v1/bootparameters"
if [ "$CHECK_KEA" = "true" ]; then
  if [ -n "${COMPOSE_FILE:-}" ]; then
    log_info "checking kea container health via docker compose"
    if [ "$DRY_RUN" = "true" ]; then
      log_info "[dry-run] would check kea health via docker compose"
    elif docker_compose -f "$COMPOSE_FILE" --env-file "${SECRETS_FILE}" ps --format json kea \
      | jq -s -e 'length == 1 and .[0].Service == "kea" and .[0].State == "running" and .[0].Health == "healthy"' >/dev/null; then
      log_info "kea is healthy"
    else
      log_error "kea is NOT healthy"
      failed=$((failed + 1))
    fi
  else
    log_info "checking kea on UDP port ${KEA_PORT} via ${PXE_INTERFACE}"
    if [ "$DRY_RUN" = "true" ]; then
      log_info "[dry-run] would check kea on UDP port ${KEA_PORT} via ${PXE_INTERFACE}"
    elif ss -lun "sport = :${KEA_PORT}" | grep -q "%${PXE_INTERFACE}:${KEA_PORT}"; then
      log_info "kea is healthy (UDP port ${KEA_PORT} is listening on ${PXE_INTERFACE})"
    else
      log_error "kea is NOT healthy"
      failed=$((failed + 1))
    fi
  fi
  check_service "Kea sync" "http://${HOST}:${KEA_SYNC_PORT}/readiness"
fi
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
