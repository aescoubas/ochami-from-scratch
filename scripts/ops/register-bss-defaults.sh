#!/usr/bin/env bash
# register-bss-defaults.sh — Register boot parameters with BSS.
#
# By default registers the "Default" host entry (fallback for any node).
# With --mac, registers boot parameters for a specific MAC address instead.
#
# Usage:
#   ./register-bss-defaults.sh [--dry-run]
#   ./register-bss-defaults.sh --mac 02:00:00:00:00:01 [--dry-run]
#   ./register-bss-defaults.sh --mac 02:00:00:00:00:01 --image-name opensuse \
#       --kernel vmlinuz --initrd opensuse-leap-live.cpio.zst \
#       --kernel-params "console=ttyS0,115200n8 console=tty0" [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

HOST="${HOST_IP:-192.168.100.1}"
HTTP_PORT="${HTTP_PORT:-80}"
BSS_PORT="${BSS_PORT:-27778}"
TEST_NODE_IMAGE="${TEST_NODE_IMAGE:-almalinux}"
TEST_NODE_IMAGE="${OPENCHAMI_TEST_NODE_IMAGE:-$TEST_NODE_IMAGE}"

MAC=""
IMAGE_NAME=""
KERNEL_FILE_OVERRIDE=""
INITRD_FILE_OVERRIDE=""
KERNEL_PARAMS_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --mac=*)           MAC="${arg#--mac=}" ;;
    --image-name=*)    IMAGE_NAME="${arg#--image-name=}" ;;
    --kernel=*)        KERNEL_FILE_OVERRIDE="${arg#--kernel=}" ;;
    --initrd=*)        INITRD_FILE_OVERRIDE="${arg#--initrd=}" ;;
    --kernel-params=*) KERNEL_PARAMS_OVERRIDE="${arg#--kernel-params=}" ;;
  esac
done
prev=""
for arg in "$@"; do
  case "$prev" in
    --mac)           MAC="$arg" ;;
    --image-name)    IMAGE_NAME="$arg" ;;
    --kernel)        KERNEL_FILE_OVERRIDE="$arg" ;;
    --initrd)        INITRD_FILE_OVERRIDE="$arg" ;;
    --kernel-params) KERNEL_PARAMS_OVERRIDE="$arg" ;;
  esac
  prev="$arg"
done

BSS_URL="http://localhost:${BSS_PORT}/boot/v1/bootparameters"

log_info "waiting for BSS to be ready..."
if [ "$DRY_RUN" = "true" ]; then
  log_info "[dry-run] would wait for $BSS_URL"
fi

# --- Resolve boot artifact metadata ---
# When --mac is used with explicit --kernel/--initrd/--kernel-params, skip
# the metadata/build-boot-artifacts path entirely.
if [ -n "$MAC" ] && [ -n "$KERNEL_FILE_OVERRIDE" ] && [ -n "$INITRD_FILE_OVERRIDE" ]; then
  # Use the provided image name or default to TEST_NODE_IMAGE
  IMAGE_NAME="${IMAGE_NAME:-$TEST_NODE_IMAGE}"
  BOOT_IMAGE_RELATIVE_DIR="artifacts/${IMAGE_NAME}"
  BOOT_IMAGE_KERNEL_FILE="$KERNEL_FILE_OVERRIDE"
  BOOT_IMAGE_INITRD_FILE="$INITRD_FILE_OVERRIDE"
  BOOT_PARAMS="${KERNEL_PARAMS_OVERRIDE:-console=ttyS0,115200n8 console=tty0}"
elif [ "$DRY_RUN" = "true" ]; then
  BOOT_PARAMS="<generated boot params>"
  IMAGE_NAME="${IMAGE_NAME:-$TEST_NODE_IMAGE}"
  BOOT_IMAGE_RELATIVE_DIR="artifacts/${IMAGE_NAME}"
  BOOT_IMAGE_KERNEL_FILE="vmlinuz"
  BOOT_IMAGE_INITRD_FILE="initrd"
else
  if [ "$DRY_RUN" != "true" ]; then
    wait_for_url "$BSS_URL" 30 2
  fi
  BOOT_ARTIFACTS_PATH="${BOOT_ARTIFACTS_PATH:-}"
  if [ -z "$BOOT_ARTIFACTS_PATH" ]; then
    log_info "building boot artifacts for ${TEST_NODE_IMAGE}..."
    "$SCRIPT_DIR/build-boot-artifacts.sh"
    BOOT_ARTIFACTS_PATH="${PROJECT_ROOT}/.tmp/boot-artifacts"
  fi
  resolve_boot_image_metadata "$BOOT_ARTIFACTS_PATH" "$TEST_NODE_IMAGE"
  KERNEL_PARAMS_FILE="${BOOT_ARTIFACTS_PATH}/${BOOT_IMAGE_RELATIVE_DIR}/kernel-params"
  if [ ! -f "$KERNEL_PARAMS_FILE" ]; then
    log_error "boot artifacts kernel params not found: $KERNEL_PARAMS_FILE"
    exit 1
  fi
  BOOT_PARAMS="$(tr '\n' ' ' < "$KERNEL_PARAMS_FILE" | xargs)"
fi

ARTIFACTS_URL="http://${HOST}:${HTTP_PORT}/${BOOT_IMAGE_RELATIVE_DIR}"

# --- Register with BSS ---
if [ -n "$MAC" ]; then
  log_info "registering boot parameters for MAC $MAC"
  run_cmd curl -sf -X PUT \
    -H 'Content-Type: application/json' \
    "$BSS_URL" \
    -d "{
      \"macs\": [\"${MAC}\"],
      \"kernel\": \"${ARTIFACTS_URL}/${BOOT_IMAGE_KERNEL_FILE}\",
      \"initrd\": \"${ARTIFACTS_URL}/${BOOT_IMAGE_INITRD_FILE}\",
      \"params\": \"${BOOT_PARAMS}\"
    }"
  log_info "BSS boot parameters registered for MAC $MAC"
else
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
fi
