#!/usr/bin/env bash
# register-bss-defaults.sh — Register default boot parameters with BSS.
# Usage: ./register-bss-defaults.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"
NIX_FLAKE_REF="${OPENCHAMI_NIX_FLAKE_REF:-$(nix_flake_ref "$PROJECT_ROOT")}"

parse_common_args "$@"

HOST="${HOST_IP:-192.168.100.1}"
HTTP_PORT="${HTTP_PORT:-80}"
BSS_PORT="${BSS_PORT:-27778}"
TEST_NODE_IMAGE="${TEST_NODE_IMAGE:-nixos}"
TEST_NODE_IMAGE="${OPENCHAMI_TEST_NODE_IMAGE:-$TEST_NODE_IMAGE}"

BSS_URL="http://localhost:${BSS_PORT}/boot/v1/bootparameters"

log_info "waiting for BSS to be ready..."
if [ "$DRY_RUN" = "true" ]; then
  log_info "[dry-run] would wait for $BSS_URL"
  BOOT_PARAMS="<generated boot params>"
else
  wait_for_url "$BSS_URL" 30 2
  BOOT_ARTIFACTS_PATH="${BOOT_ARTIFACTS_PATH:-}"
  if [ -z "$BOOT_ARTIFACTS_PATH" ]; then
    BOOT_ARTIFACTS_OUTPUT="$(boot_artifacts_output_for_image "$TEST_NODE_IMAGE")"
    log_info "building ${BOOT_ARTIFACTS_OUTPUT} with nix..."
    BOOT_ARTIFACTS_PATH="$(
      cd "$PROJECT_ROOT" && OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE" \
        nix build --impure "${NIX_FLAKE_REF}#${BOOT_ARTIFACTS_OUTPUT}" --no-link --print-out-paths
    )"
  fi
  resolve_boot_image_metadata "$BOOT_ARTIFACTS_PATH" "$TEST_NODE_IMAGE"
  KERNEL_PARAMS_FILE="${BOOT_ARTIFACTS_PATH}/${BOOT_IMAGE_RELATIVE_DIR}/kernel-params"
  if [ ! -f "$KERNEL_PARAMS_FILE" ]; then
    log_error "boot artifacts kernel params not found: $KERNEL_PARAMS_FILE"
    exit 1
  fi
  BOOT_PARAMS="$(tr '\n' ' ' < "$KERNEL_PARAMS_FILE" | xargs)"
fi

if [ "$DRY_RUN" = "true" ]; then
  BOOT_IMAGE_RELATIVE_DIR="artifacts/${TEST_NODE_IMAGE}"
  BOOT_IMAGE_KERNEL_FILE="vmlinuz"
  BOOT_IMAGE_INITRD_FILE="initrd"
fi

ARTIFACTS_URL="http://${HOST}:${HTTP_PORT}/${BOOT_IMAGE_RELATIVE_DIR}"

log_info "registering default boot parameters"
run_cmd curl -sf -X PUT \
  -H 'Content-Type: application/json' \
  "$BSS_URL" \
  -d "{
    \"hosts\": [\"Default\"],
    \"kernel\": \"${ARTIFACTS_URL}/${BOOT_IMAGE_KERNEL_FILE}\",
    \"initrd\": \"${ARTIFACTS_URL}/${BOOT_IMAGE_INITRD_FILE}\",
    \"params\": \"${BOOT_PARAMS}\"
  }"

log_info "BSS default boot parameters registered"
