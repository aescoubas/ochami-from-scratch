#!/usr/bin/env bash
# check-deps.sh — Check that required dependencies are installed.
# Usage: ./check-deps.sh --method compose|quadlets|minikube [--dry-run]
#
# Checks only — does NOT install anything. Exits non-zero if deps are missing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
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
    check envsubst "template rendering"
    check ss "socket inspection"
    check ip "network interface management"
    check timeout "command timeout"
    check docker "container runtime"
    check virsh "libvirt management"
    if docker_compose_available; then
      log_info "  ✓ $(docker_compose_label)"
    else
      log_warn "  ✗ docker compose (neither v1 nor v2 found)"
      missing=$((missing + 1))
    fi
    if command_exists docker; then
      if docker_daemon_reachable; then
        log_info "  ✓ docker daemon reachable"
      else
        log_warn "  ✗ docker daemon reachable"
        missing=$((missing + 1))
      fi
    fi
    if [ "$(uname -s)" = "Darwin" ] && [ "${OPENCHAMI_ALLOW_UNSUPPORTED_DARWIN:-}" != "1" ]; then
      log_warn "  ✗ macOS compose PXE is unsupported (requires Linux host networking and libvirt bridge management)"
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
  log_error "$missing required dependency check(s) failed"
  exit 1
fi

log_info "all dependencies satisfied for method=$METHOD"
