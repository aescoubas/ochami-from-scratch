#!/usr/bin/env bash
# build-images.sh — Build all OpenCHAMI OCI images via Nix and load into docker/podman.
#
# Usage: ./build-images.sh [--runtime docker|podman]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

RUNTIME="${CONTAINER_RUNTIME:-docker}"

# Parse arguments.
while [ $# -gt 0 ]; do
  case "$1" in
    --runtime)
      RUNTIME="${2:-docker}"
      shift 2
      ;;
    --runtime=*)
      RUNTIME="${1#--runtime=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

require_command nix "Nix is required to build OCI images"
require_command "$RUNTIME" "$RUNTIME is required to load OCI images"

IMAGES=(
  oci-smd
  oci-bss
  oci-pcs
  oci-cloud-init
  oci-http-server
  oci-tftp
  oci-kea-sidecar
)

FAILED=0

for img in "${IMAGES[@]}"; do
  log_info "building $img..."
  path=$(nix build ".#$img" --no-link --print-out-paths 2>/dev/null)
  if [ -z "$path" ] || [ ! -f "$path" ]; then
    log_error "failed to build $img"
    FAILED=$((FAILED + 1))
    continue
  fi
  log_info "loading $img into $RUNTIME..."
  "$RUNTIME" load < "$path"
done

if [ "$FAILED" -gt 0 ]; then
  log_error "$FAILED image(s) failed to build"
  exit 1
fi

log_info "all images built and loaded successfully"
