#!/usr/bin/env bash
# check-deps.sh — Check that required dependencies are installed.
# Usage: ./check-deps.sh --method compose|quadlets|minikube [--dry-run]
#
# Checks only — does NOT install anything. Exits non-zero if deps are missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

METHOD=""
parse_common_args "$@"

if [ -z "$METHOD" ]; then
  log_error "usage: $0 --method compose|quadlets|minikube"
  exit 1
fi

missing=0

check() {
  local cmd="$1"
  local purpose="${2:-}"
  if command_exists "$cmd"; then
    log_info "  ✓ $cmd"
  else
    log_warn "  ✗ $cmd${purpose:+ ($purpose)}"
    missing=$((missing + 1))
  fi
}

log_info "checking common dependencies..."
check curl "HTTP client"
check jq "JSON processor"

case "$METHOD" in
  compose|docker-compose)
    log_info "checking docker-compose dependencies..."
    check docker "container runtime"
    if command_exists docker-compose; then
      log_info "  ✓ docker-compose (v1)"
    elif docker compose version &>/dev/null; then
      log_info "  ✓ docker compose (v2 plugin)"
    else
      log_warn "  ✗ docker compose (neither v1 nor v2 found)"
      missing=$((missing + 1))
    fi
    ;;

  quadlets)
    log_info "checking quadlet dependencies..."
    check podman "container runtime"
    check systemctl "systemd control"
    ;;

  minikube)
    log_info "checking minikube dependencies..."
    check minikube "Kubernetes cluster"
    check kubectl "Kubernetes CLI"
    check helm "Helm package manager"
    check docker "container runtime (for image builds)"
    ;;

  *)
    log_error "unknown method: $METHOD (expected compose, quadlets, or minikube)"
    exit 1
    ;;
esac

if [ "$missing" -gt 0 ]; then
  log_error "$missing required command(s) not found"
  exit 1
fi

log_info "all dependencies satisfied for method=$METHOD"
