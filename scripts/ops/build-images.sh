#!/usr/bin/env bash
# build-images.sh — Build OpenCHAMI OCI images using buildah/docker/podman.
#
# Usage:
#   ./build-images.sh [--dry-run] [--profile official|dev|cscs] [service ...]
#
# Examples:
#   ./build-images.sh                         # build all images, official profile
#   ./build-images.sh smd bss                 # build only smd and bss
#   ./build-images.sh --profile dev           # build all with dev profile refs
#   ./build-images.sh --dry-run               # show what would be built
#
# Environment:
#   CONTAINER_RUNTIME   — force podman, docker, or buildah (default: auto-detect)
#   OPENCHAMI_PROFILE   — profile name (default: official)
#   SMD_SRC             — local source checkout for smd
#   BSS_SRC             — local source checkout for bss
#   PCS_SRC             — local source checkout for pcs
#   CLOUD_INIT_SRC      — local source checkout for cloud-init
#   KEA_SYNC_SRC        — local source checkout for kea-sync

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source shared utilities.
. "$SCRIPT_DIR/lib/common.sh"

# --- Configuration ---

PROFILE="${OPENCHAMI_PROFILE:-official}"
PROFILE_FILE="${PROJECT_ROOT}/profiles/${PROFILE}.env"
DRY_RUN="${DRY_RUN:-false}"

# Services that build from source (have SOURCE_REPO / SOURCE_REF build args).
# Maps the image directory name to the env-var prefix used for overrides.
declare -A SOURCE_SERVICES=(
  [smd]=SMD
  [bss]=BSS
  [pcs]=PCS
  [cloud-init]=CLOUD_INIT
  [kea-sync]=KEA_SYNC
)

# Positional arguments: services to build (empty = all).
REQUESTED_SERVICES=()

# --- Argument parsing ---

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --profile)
      PROFILE="${2:-official}"
      PROFILE_FILE="${PROJECT_ROOT}/profiles/${PROFILE}.env"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#--profile=}"
      PROFILE_FILE="${PROJECT_ROOT}/profiles/${PROFILE}.env"
      shift
      ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# \{0,1\}//; p }' "$0"
      exit 0
      ;;
    -*)
      log_error "unknown flag: $1"
      exit 1
      ;;
    *)
      REQUESTED_SERVICES+=("$1")
      shift
      ;;
  esac
done

# --- Load profile ---

if [ ! -f "$PROFILE_FILE" ]; then
  log_error "profile file not found: $PROFILE_FILE"
  exit 1
fi

# shellcheck disable=SC1090
. "$PROFILE_FILE"

log_info "loaded profile: ${PROFILE} (${PROFILE_FILE})"

# --- Detect container runtime ---

detect_runtime() {
  if [ -n "${CONTAINER_RUNTIME:-}" ]; then
    printf '%s' "$CONTAINER_RUNTIME"
    return 0
  fi

  local candidate
  for candidate in podman buildah docker; do
    if command_exists "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  log_error "no container runtime found (tried podman, buildah, docker)"
  return 1
}

RUNTIME="$(detect_runtime)"
require_command "$RUNTIME" "container runtime for building OCI images"

# When the runtime is buildah, the build subcommand is "bud"; for
# podman/docker it is "build".
build_cmd() {
  if [ "$RUNTIME" = "buildah" ]; then
    "$RUNTIME" bud "$@"
  else
    "$RUNTIME" build "$@"
  fi
}

log_info "container runtime: ${RUNTIME}"

# --- Helpers ---

normalize_oci_tag() {
  local raw_tag="$1"
  local normalized

  normalized="$(printf '%s' "$raw_tag" | sed -E 's/[^A-Za-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
  if [ -z "$normalized" ]; then
    normalized="local"
  fi

  printf '%s\n' "$normalized"
}

# Derive a descriptive ref string from a local git checkout, appending
# "-dirty" when the work tree has uncommitted changes.
checkout_ref_for_image_tag() {
  local checkout_path="$1"
  local ref

  if ref="$(git -C "$checkout_path" describe --tags --exact-match 2>/dev/null)"; then
    :
  elif ref="$(git -C "$checkout_path" symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
    :
  else
    ref="$(git -C "$checkout_path" rev-parse --short=12 HEAD)"
  fi

  if ! git -C "$checkout_path" diff --quiet --ignore-submodules HEAD -- >/dev/null 2>&1; then
    ref="${ref}-dirty"
  fi

  printf '%s\n' "$ref"
}

# --- Discover services ---

discover_services() {
  local service_dir
  for service_dir in "$PROJECT_ROOT"/images/*/; do
    [ -f "${service_dir}Dockerfile" ] || continue
    basename "$service_dir"
  done
}

ALL_SERVICES=()
while IFS= read -r svc; do
  ALL_SERVICES+=("$svc")
done < <(discover_services | sort)

if [ ${#ALL_SERVICES[@]} -eq 0 ]; then
  log_error "no services with Dockerfiles found under images/"
  exit 1
fi

# Validate requested services.
if [ ${#REQUESTED_SERVICES[@]} -gt 0 ]; then
  for req in "${REQUESTED_SERVICES[@]}"; do
    found=false
    for svc in "${ALL_SERVICES[@]}"; do
      if [ "$req" = "$svc" ]; then
        found=true
        break
      fi
    done
    if [ "$found" != "true" ]; then
      log_error "unknown service: $req (available: ${ALL_SERVICES[*]})"
      exit 1
    fi
  done
  BUILD_SERVICES=("${REQUESTED_SERVICES[@]}")
else
  BUILD_SERVICES=("${ALL_SERVICES[@]}")
fi

log_info "services to build: ${BUILD_SERVICES[*]}"

# --- Build loop ---

BUILT_IMAGES=()
FAILED_SERVICES=()

for service in "${BUILD_SERVICES[@]}"; do
  dockerfile="${PROJECT_ROOT}/images/${service}/Dockerfile"
  build_context="${PROJECT_ROOT}/images/${service}/"

  # Determine build args and image tag for this service.
  build_args=()
  tag="latest"

  env_prefix="${SOURCE_SERVICES[$service]:-}"
  if [ -n "$env_prefix" ]; then
    # This is a source-built service with SOURCE_REPO / SOURCE_REF args.
    ref_var="${env_prefix}_REF"
    repo_var="${env_prefix}_REPO"
    src_var="${env_prefix}_SRC"
    source_ref="${!ref_var:-main}"
    source_repo="${!repo_var:-}"
    local_src="${!src_var:-}"

    if [ -n "$local_src" ]; then
      # Local source override. Validate the checkout, then derive the ref
      # from the local git state. The Dockerfile still clones from the
      # upstream repo URL, but we override SOURCE_REF to the commit SHA
      # so the exact same code is built. The image is tagged with the
      # local ref (branch, tag, or short SHA, plus -dirty if applicable).
      if [ ! -d "$local_src" ]; then
        log_error "${service}: local source does not exist: ${local_src}"
        FAILED_SERVICES+=("$service")
        continue
      fi

      if ! git -C "$local_src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_error "${service}: local source is not a git checkout: ${local_src}"
        FAILED_SERVICES+=("$service")
        continue
      fi

      local_ref="$(checkout_ref_for_image_tag "$local_src")"
      # Use the full commit SHA so the Dockerfile can check it out from
      # the upstream repo (assuming it has been pushed).
      local_commit="$(git -C "$local_src" rev-parse HEAD)"
      tag="$(normalize_oci_tag "$local_ref")"

      build_args+=(--build-arg "SOURCE_REPO=${source_repo}")
      build_args+=(--build-arg "SOURCE_REF=${local_commit}")
      log_info "${service}: local override ${local_src} at ${local_ref}"
    else
      # Standard build: use the profile's repo and ref.
      tag="$(normalize_oci_tag "$source_ref")"
      build_args+=(--build-arg "SOURCE_REPO=${source_repo}")
      build_args+=(--build-arg "SOURCE_REF=${source_ref}")
    fi
  fi

  # Compute the full image name.
  if [ -n "${IMAGE_REGISTRY:-}" ]; then
    image_name="${IMAGE_REGISTRY}/${IMAGE_PREFIX:-}${service}:${tag}"
  else
    image_name="localhost/${IMAGE_PREFIX:-}${service}:${tag}"
  fi

  log_info "building ${image_name}"

  if [ "$DRY_RUN" = "true" ]; then
    log_info "[dry-run] ${RUNTIME} build -t ${image_name} -f ${dockerfile} ${build_args[*]:-} ${build_context}"
    BUILT_IMAGES+=("$image_name")
    continue
  fi

  if build_cmd -t "$image_name" -f "$dockerfile" "${build_args[@]}" "$build_context"; then
    BUILT_IMAGES+=("$image_name")
  else
    log_error "failed to build ${service}"
    FAILED_SERVICES+=("$service")
  fi
done

# --- Summary ---

echo ""
log_info "=== Build Summary ==="
log_info "profile: ${PROFILE}"
log_info "runtime: ${RUNTIME}"

if [ ${#BUILT_IMAGES[@]} -gt 0 ]; then
  log_info "built ${#BUILT_IMAGES[@]} image(s):"
  for img in "${BUILT_IMAGES[@]}"; do
    log_info "  ${img}"
  done
fi

if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
  log_error "failed ${#FAILED_SERVICES[@]} service(s): ${FAILED_SERVICES[*]}"
  exit 1
fi

log_info "all images built successfully"
