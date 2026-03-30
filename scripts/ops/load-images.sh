#!/usr/bin/env bash
# load-images.sh — Load pre-built OCI image archives into a local or remote podman.
#
# Usage:
#   # Local: load images into local podman
#   ./load-images.sh /path/to/oci-images-dir
#
#   # Remote: load images into a remote host via SSH
#   ./load-images.sh --remote user@host /path/to/oci-images-dir
#
# The image directory should contain .tar.gz OCI archives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

REMOTE=""
RUNTIME="podman"
IMAGE_DIR=""
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

usage() {
  cat <<EOF
Usage: $0 [--remote user@host] [--ssh-key path] [--runtime podman|docker] IMAGE_DIR

Options:
  --remote HOST    Load images on a remote host via SSH
  --ssh-key PATH   SSH private key for remote access
  --runtime RT     Container runtime (default: podman)
  IMAGE_DIR        Directory containing .tar.gz OCI image archives
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --remote)
      REMOTE="$2"
      shift 2
      ;;
    --ssh-key)
      SSH_OPTS="$SSH_OPTS -o IdentitiesOnly=yes -i $2"
      shift 2
      ;;
    --runtime)
      RUNTIME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      IMAGE_DIR="$1"
      shift
      ;;
  esac
done

if [ -z "$IMAGE_DIR" ]; then
  log_error "IMAGE_DIR is required"
  usage
  exit 1
fi

if [ ! -d "$IMAGE_DIR" ]; then
  log_error "image directory does not exist: $IMAGE_DIR"
  exit 1
fi

load_local() {
  local archive="$1"
  local name
  name="$(basename "$archive")"
  log_info "loading $name..."
  sudo "$RUNTIME" load < "$archive"
}

load_remote() {
  local archive="$1"
  local name
  name="$(basename "$archive")"
  log_info "loading $name on $REMOTE..."
  # Stream the archive directly to the remote host — avoids copying files
  ssh $SSH_OPTS "$REMOTE" "sudo $RUNTIME load" < "$archive"
}

FOUND=0
for archive in "$IMAGE_DIR"/*.tar.gz; do
  [ -e "$archive" ] || continue
  FOUND=1

  # Resolve symlinks (Nix store paths are often symlinked)
  archive="$(readlink -f "$archive")"

  if [ -n "$REMOTE" ]; then
    load_remote "$archive"
  else
    load_local "$archive"
  fi
done

if [ "$FOUND" -eq 0 ]; then
  log_error "no .tar.gz archives found in $IMAGE_DIR"
  exit 1
fi

log_info "all images loaded successfully"
