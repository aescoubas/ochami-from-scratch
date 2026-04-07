#!/usr/bin/env bash
# push-boot-artifacts.sh — Push pre-built boot artifacts to an OpenCHAMI server.
#
# Copies kernel and initrd (or cpio) files to the HTTP-served artifacts
# directory on the target host via rsync over SSH.
#
# Usage:
#   ./push-boot-artifacts.sh --host <server> --artifacts-dir <local-dir> [--image-name <name>] [--dry-run]
#
# Environment:
#   SSH_USER          SSH user (default: current user)
#   REMOTE_DIR        Remote base path (default: /etc/openchami/artifacts)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

HOST=""
ARTIFACTS_DIR=""
IMAGE_NAME=""

for arg in "$@"; do
  case "$arg" in
    --host=*)          HOST="${arg#--host=}" ;;
    --artifacts-dir=*) ARTIFACTS_DIR="${arg#--artifacts-dir=}" ;;
    --image-name=*)    IMAGE_NAME="${arg#--image-name=}" ;;
  esac
done
# Handle --flag VALUE form
prev=""
for arg in "$@"; do
  case "$prev" in
    --host)          HOST="$arg" ;;
    --artifacts-dir) ARTIFACTS_DIR="$arg" ;;
    --image-name)    IMAGE_NAME="$arg" ;;
  esac
  prev="$arg"
done

SSH_USER="${SSH_USER:-$(whoami)}"
REMOTE_BASE="${REMOTE_DIR:-/etc/openchami/artifacts}"

if [ -z "$HOST" ]; then
  log_error "usage: $0 --host <server> --artifacts-dir <local-dir> [--image-name <name>] [--dry-run]"
  exit 1
fi

if [ -z "$ARTIFACTS_DIR" ]; then
  log_error "--artifacts-dir is required (directory containing kernel + initrd files)"
  exit 1
fi

if [ ! -d "$ARTIFACTS_DIR" ]; then
  log_error "artifacts directory not found: $ARTIFACTS_DIR"
  exit 1
fi

# Derive image name from directory basename if not provided
if [ -z "$IMAGE_NAME" ]; then
  IMAGE_NAME="$(basename "$ARTIFACTS_DIR")"
fi

REMOTE_PATH="${REMOTE_BASE}/${IMAGE_NAME}"

log_info "pushing boot artifacts to ${HOST}:${REMOTE_PATH}"
log_info "  source: $ARTIFACTS_DIR"
log_info "  image:  $IMAGE_NAME"

# List what we're pushing
for f in "$ARTIFACTS_DIR"/*; do
  [ -f "$f" ] || continue
  log_info "  $(basename "$f") ($(du -sh "$f" | cut -f1))"
done

run_cmd ssh "${SSH_USER}@${HOST}" "sudo mkdir -p ${REMOTE_PATH}"

run_cmd rsync -avz --progress --rsync-path="sudo rsync" \
  "$ARTIFACTS_DIR/" \
  "${SSH_USER}@${HOST}:${REMOTE_PATH}/"

run_cmd ssh "${SSH_USER}@${HOST}" "sudo chmod -R 644 ${REMOTE_PATH}/ && sudo chmod 755 ${REMOTE_PATH}"

log_info "boot artifacts pushed to ${HOST}:${REMOTE_PATH}"
