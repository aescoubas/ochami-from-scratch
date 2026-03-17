#!/usr/bin/env bash
# build-images.sh — Build all OpenCHAMI OCI images via Nix and load into docker/podman.
#
# Usage: ./build-images.sh [--runtime docker|podman]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WORKSPACE_ROOT="$(dirname "$(dirname "$PROJECT_ROOT")")"
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
require_command git "git is required to check out private OCI image sources"

IMAGES=(
  oci-smd
  oci-bss
  oci-pcs
  oci-cloud-init
  oci-kea
  oci-http-server
  oci-tftp
  oci-kea-sync
)

KEA_SYNC_REPO="${KEA_SYNC_REPO:-git@github.com:OpenCHAMI/kea-sync.git}"
KEA_SYNC_CHECKOUT="${KEA_SYNC_CHECKOUT:-${WORKSPACE_ROOT}/services/kea-sync}"

ensure_kea_sync_src() {
  if [ -n "${KEA_SYNC_SRC:-}" ]; then
    return 0
  fi

  if [ -d "${KEA_SYNC_CHECKOUT}/.git" ]; then
    KEA_SYNC_SRC="${KEA_SYNC_CHECKOUT}"
    return 0
  fi

  if [ -e "${KEA_SYNC_CHECKOUT}" ] && [ ! -d "${KEA_SYNC_CHECKOUT}/.git" ]; then
    log_error "kea-sync checkout path exists but is not a git checkout: ${KEA_SYNC_CHECKOUT}"
    return 1
  fi

  mkdir -p "$(dirname "${KEA_SYNC_CHECKOUT}")"
  log_info "cloning kea-sync source from ${KEA_SYNC_REPO} into ${KEA_SYNC_CHECKOUT}"
  git clone --depth 1 "${KEA_SYNC_REPO}" "${KEA_SYNC_CHECKOUT}"
  KEA_SYNC_SRC="${KEA_SYNC_CHECKOUT}"
}

ensure_kea_sync_src || exit 1

FAILED=0

for img in "${IMAGES[@]}"; do
  log_info "building $img..."
  if [ "$img" = "oci-kea-sync" ] && [ -n "${KEA_SYNC_SRC:-}" ]; then
    log_info "using kea-sync source from ${KEA_SYNC_SRC}"
    path=$(KEA_SYNC_SRC="${KEA_SYNC_SRC}" nix build --impure ".#$img" --no-link --print-out-paths 2>/dev/null)
  else
    path=$(nix build ".#$img" --no-link --print-out-paths 2>/dev/null)
  fi
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
