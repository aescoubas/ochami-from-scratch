#!/usr/bin/env bash
# register-bss-defaults.sh — Register default boot parameters with BSS.
# Usage: ./register-bss-defaults.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

HOST="${HOST_IP:-192.168.100.1}"
HTTP_PORT="${HTTP_PORT:-80}"
BSS_PORT="${BSS_PORT:-27778}"

BSS_URL="http://localhost:${BSS_PORT}/boot/v1/bootparameters"
ARTIFACTS_URL="http://${HOST}:${HTTP_PORT}/artifacts/opensuse"

log_info "waiting for BSS to be ready..."
if [ "$DRY_RUN" = "true" ]; then
  log_info "[dry-run] would wait for $BSS_URL"
else
  wait_for_url "$BSS_URL" 30 2
fi

log_info "registering default boot parameters"
run_cmd curl -sf -X PUT \
  -H 'Content-Type: application/json' \
  "$BSS_URL" \
  -d "{
    \"hosts\": [\"Default\"],
    \"kernel\": \"${ARTIFACTS_URL}/vmlinuz-lts\",
    \"initrd\": \"${ARTIFACTS_URL}/initramfs-lts\",
    \"params\": \"console=ttyS0 ip=dhcp rd.neednet=1 root=live:${ARTIFACTS_URL}/rootfs.squashfs\"
  }"

log_info "BSS default boot parameters registered"
