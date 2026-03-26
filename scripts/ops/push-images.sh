#!/usr/bin/env bash
# push-images.sh — Tag and push locally-built OCI images to a remote registry.
#
# Usage:
#   # Push all localhost/<prefix>* images
#   ./push-images.sh --registry jfrog.svc.cscs.ch/docker/openchami
#
#   # Push only images matching a prefix
#   ./push-images.sh --registry jfrog.svc.cscs.ch/docker/openchami --prefix cscs-
#
#   # Dry run — show what would be pushed without actually pushing
#   ./push-images.sh --registry jfrog.svc.cscs.ch/docker/openchami --dry-run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

REGISTRY=""
PREFIX=""
RUNTIME="podman"
DRY_RUN=false
USE_SUDO=true

usage() {
  cat <<EOF
Usage: $0 --registry REGISTRY [--prefix PREFIX] [--runtime podman|docker] [--no-sudo] [--dry-run]

Options:
  --registry REG   Target registry (e.g. jfrog.svc.cscs.ch/docker/openchami)
  --prefix PREFIX  Only push images matching localhost/PREFIX* (e.g. cscs-)
  --runtime RT     Container runtime (default: podman)
  --no-sudo        Run podman/docker without sudo
  --dry-run        Show what would be pushed without pushing
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --registry)
      REGISTRY="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --runtime)
      RUNTIME="$2"
      shift 2
      ;;
    --no-sudo)
      USE_SUDO=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_error "unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [ -z "$REGISTRY" ]; then
  log_error "--registry is required"
  usage
  exit 1
fi

# Strip trailing slash from registry
REGISTRY="${REGISTRY%/}"

run_rt() {
  if $USE_SUDO; then
    sudo "$RUNTIME" "$@"
  else
    "$RUNTIME" "$@"
  fi
}

# List matching images: REPOSITORY:TAG
filter="localhost/${PREFIX}"
images=$(run_rt images --format '{{.Repository}}:{{.Tag}}' | grep "^${filter}" || true)

if [ -z "$images" ]; then
  log_error "no images found matching ${filter}*"
  exit 1
fi

PUSHED=0
while IFS= read -r image; do
  # image = localhost/cscs-bss:v1.32.2
  # Extract name and tag
  name_with_tag="${image#localhost/}"   # cscs-bss:v1.32.2
  remote_ref="${REGISTRY}/${name_with_tag}"

  if $DRY_RUN; then
    log_info "[dry-run] would tag $image -> $remote_ref"
    log_info "[dry-run] would push $remote_ref"
  else
    log_info "tagging $image -> $remote_ref"
    run_rt tag "$image" "$remote_ref"

    log_info "pushing $remote_ref"
    run_rt push "$remote_ref"
  fi
  PUSHED=$((PUSHED + 1))
done <<< "$images"

if $DRY_RUN; then
  log_info "dry run complete — $PUSHED image(s) would be pushed"
else
  log_info "pushed $PUSHED image(s) to $REGISTRY"
fi
