#!/usr/bin/env bash
# build-images.sh — Build all OpenCHAMI OCI images via Nix and load into docker/podman.
#
# Usage: ./build-images.sh [--runtime docker|podman] [--profile official|dev]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
WORKSPACE_ROOT="$(dirname "$(dirname "$PROJECT_ROOT")")"
. "$SCRIPT_DIR/lib/common.sh"
NIX_FLAKE_REF="${OPENCHAMI_NIX_FLAKE_REF:-$(nix_flake_ref "$PROJECT_ROOT")}"

RUNTIME="${CONTAINER_RUNTIME:-docker}"
PROFILE="${OPENCHAMI_PROFILE:-official}"

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
    --profile)
      PROFILE="${2:-official}"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#--profile=}"
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

KEA_SYNC_REPO="${KEA_SYNC_REPO:-https://github.com/aescoubas/kea-sync.git}"
KEA_SYNC_CHECKOUT="${KEA_SYNC_CHECKOUT:-${WORKSPACE_ROOT}/services/kea-sync}"
KEA_SYNC_MANAGED_CHECKOUT="false"
OCI_IMAGES_OUTPUT="$(flake_output_for_profile "oci-images" "$PROFILE")"

kea_sync_ref_for_profile() {
  nix eval --raw --impure --expr "let profile = import ${PROJECT_ROOT}/nix/profiles/${PROFILE}.nix; in profile.refs.keaSync"
}

ensure_kea_sync_src() {
  if [ -n "${KEA_SYNC_SRC:-}" ]; then
    return 0
  fi

  if [ -d "${KEA_SYNC_CHECKOUT}/.git" ]; then
    KEA_SYNC_SRC="${KEA_SYNC_CHECKOUT}"
    KEA_SYNC_MANAGED_CHECKOUT="true"
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
  KEA_SYNC_MANAGED_CHECKOUT="true"
}

ensure_kea_sync_ref() {
  local requested_ref="$1"
  local requested_commit current_commit

  if [ ! -d "${KEA_SYNC_SRC}/.git" ]; then
    log_error "KEA_SYNC_SRC is not a git checkout: ${KEA_SYNC_SRC}"
    return 1
  fi

  git -C "${KEA_SYNC_SRC}" fetch --tags origin "${requested_ref}" >/dev/null 2>&1 || true
  requested_commit="$(git -C "${KEA_SYNC_SRC}" rev-parse "${requested_ref}^{commit}" 2>/dev/null || true)"
  if [ -z "$requested_commit" ]; then
    log_error "failed to resolve kea-sync ref '${requested_ref}' in ${KEA_SYNC_SRC}"
    return 1
  fi

  current_commit="$(git -C "${KEA_SYNC_SRC}" rev-parse HEAD)"
  if [ "$current_commit" = "$requested_commit" ]; then
    return 0
  fi

  if [ "$KEA_SYNC_MANAGED_CHECKOUT" = "true" ]; then
    log_info "checking out kea-sync ref ${requested_ref} in ${KEA_SYNC_SRC}"
    git -C "${KEA_SYNC_SRC}" checkout --force "${requested_ref}" >/dev/null 2>&1
    return 0
  fi

  log_error "KEA_SYNC_SRC (${KEA_SYNC_SRC}) is not at requested ref ${requested_ref}"
  return 1
}

ensure_kea_sync_src || exit 1
KEA_SYNC_REF="$(kea_sync_ref_for_profile)"
ensure_kea_sync_ref "${KEA_SYNC_REF}" || exit 1

log_info "building ${OCI_IMAGES_OUTPUT} for profile=${PROFILE}..."
IMAGE_BUNDLE_PATH="$(
  KEA_SYNC_SRC="${KEA_SYNC_SRC}" \
    nix build --impure "${NIX_FLAKE_REF}#${OCI_IMAGES_OUTPUT}" --no-link --print-out-paths 2>/dev/null
)"

if [ -z "$IMAGE_BUNDLE_PATH" ] || [ ! -d "$IMAGE_BUNDLE_PATH" ]; then
  log_error "failed to build ${OCI_IMAGES_OUTPUT}"
  exit 1
fi

FOUND_ARCHIVES=0
for archive in "$IMAGE_BUNDLE_PATH"/*.tar.gz; do
  [ -e "$archive" ] || continue
  FOUND_ARCHIVES=1
  log_info "loading $(basename "$archive") into $RUNTIME..."
  "$RUNTIME" load < "$archive"
done

if [ "$FOUND_ARCHIVES" -ne 1 ]; then
  log_error "no OCI archives were produced by ${OCI_IMAGES_OUTPUT}"
  exit 1
fi

log_info "all profile=${PROFILE} images built and loaded successfully"
