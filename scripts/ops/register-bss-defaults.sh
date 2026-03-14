#!/usr/bin/env bash
# register-bss-defaults.sh — Register default boot parameters with BSS.
# Usage: ./register-bss-defaults.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

HOST="${HOST_IP:-192.168.100.1}"
HTTP_PORT="${HTTP_PORT:-80}"
BSS_PORT="${BSS_PORT:-27778}"
ARTIFACT_SUBDIR="${ARTIFACT_SUBDIR:-artifacts/opensuse}"

BSS_URL="http://localhost:${BSS_PORT}/boot/v1/bootparameters"
ARTIFACTS_URL="http://${HOST}:${HTTP_PORT}/${ARTIFACT_SUBDIR}"

log_info "waiting for BSS to be ready..."
if [ "$DRY_RUN" = "true" ]; then
  log_info "[dry-run] would wait for $BSS_URL"
  BOOT_PARAMS="<generated boot params>"
else
  wait_for_url "$BSS_URL" 30 2
  BOOT_ARTIFACTS_PATH="${BOOT_ARTIFACTS_PATH:-}"
  if [ -z "$BOOT_ARTIFACTS_PATH" ]; then
    log_info "building boot artifacts with nix..."
    BOOT_ARTIFACTS_PATH="$(cd "$PROJECT_ROOT" && nix build .#boot-artifacts --no-link --print-out-paths)"
  fi
  KERNEL_PARAMS_FILE="${BOOT_ARTIFACTS_PATH}/${ARTIFACT_SUBDIR}/kernel-params"
  if [ ! -f "$KERNEL_PARAMS_FILE" ]; then
    log_error "boot artifacts kernel params not found: $KERNEL_PARAMS_FILE"
    exit 1
  fi
  BOOT_PARAMS="$(tr '\n' ' ' < "$KERNEL_PARAMS_FILE" | xargs)"
fi

log_info "registering default boot parameters"
run_cmd curl -sf -X PUT \
  -H 'Content-Type: application/json' \
  "$BSS_URL" \
  -d "{
    \"hosts\": [\"Default\"],
    \"kernel\": \"${ARTIFACTS_URL}/vmlinuz-lts\",
    \"initrd\": \"${ARTIFACTS_URL}/initramfs-lts\",
    \"params\": \"${BOOT_PARAMS}\"
  }"

log_info "BSS default boot parameters registered"
