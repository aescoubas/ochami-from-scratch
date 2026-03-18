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
  log_error "usage: $0 --method compose|lab-vm|quadlets|minikube"
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

check_lab_vm_libvirt_access() {
  local libvirt_uri="${LAB_VM_LIBVIRT_URI:-$(default_lab_vm_libvirt_uri)}"

  if virsh --connect "$libvirt_uri" uri >/dev/null 2>&1; then
    log_info "  ✓ libvirt URI reachable: $libvirt_uri"
    return 0
  fi

  if ! libvirt_uri_is_session "$libvirt_uri" && sudo -n virsh --connect "$libvirt_uri" uri >/dev/null 2>&1; then
    log_info "  ✓ libvirt URI reachable with passwordless sudo: $libvirt_uri"
    return 0
  fi

  log_warn "  ✗ libvirt URI reachable: $libvirt_uri"
  missing=$((missing + 1))
}

check_remote_lab_vm_build_host() {
  local build_host="$1"
  local remote_repo_path="${OPENCHAMI_LAB_VM_BUILD_REPO_PATH:-$PROJECT_ROOT}"
  local ssh_opts="${OPENCHAMI_LAB_VM_BUILD_SSH_OPTS:-}"
  local remote_repo_path_quoted

  if ! command_exists ssh; then
    log_warn "  ✗ ssh (required for OPENCHAMI_LAB_VM_BUILD_HOST=$build_host)"
    missing=$((missing + 1))
    return 1
  fi

  log_info "  ✓ ssh"

  if ssh ${ssh_opts:+$ssh_opts }-o BatchMode=yes "$build_host" "command -v nix >/dev/null 2>&1"; then
    log_info "  ✓ remote nix reachable on $build_host"
  else
    log_warn "  ✗ remote nix reachable on $build_host"
    missing=$((missing + 1))
  fi

  remote_repo_path_quoted="$(printf '%q' "$remote_repo_path")"
  if ssh ${ssh_opts:+$ssh_opts }-o BatchMode=yes "$build_host" "test -d $remote_repo_path_quoted"; then
    log_info "  ✓ remote repo path exists on $build_host: $remote_repo_path"
  else
    log_warn "  ✗ remote repo path exists on $build_host: $remote_repo_path"
    missing=$((missing + 1))
  fi

  if [ "$(uname -s)" = "Darwin" ]; then
    if sudo -n true >/dev/null 2>&1; then
      log_info "  ✓ passwordless sudo available for trusted Nix store imports"
    else
      log_warn "  ✗ passwordless sudo available for trusted Nix store imports"
      missing=$((missing + 1))
    fi
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

  lab-vm)
    log_info "checking lab-vm dependencies..."
    check nix "Nix is required to build and run the controller VM"
    check virsh "libvirt management"
    if command_exists virsh; then
      check_lab_vm_libvirt_access
    fi
    if [ "$(uname -s)" = "Linux" ]; then
      check qemu-img "disk image creation"
      check mkfs.ext4 "ext4 disk formatting"
    elif [ "$(uname -s)" = "Darwin" ]; then
      log_info "  ✓ qemu-system-x86_64 and qemu-img will be provided by the Nix-built lab VM closure on Darwin"
    fi
    if [ "$(uname -s)" = "Darwin" ] && ! nix_has_linux_builder; then
      if [ -n "${OPENCHAMI_LAB_VM_BUILD_HOST:-}" ]; then
        check_remote_lab_vm_build_host "$OPENCHAMI_LAB_VM_BUILD_HOST"
      else
        log_warn "  ! no x86_64-linux builder or OPENCHAMI_LAB_VM_BUILD_HOST detected; first-time macOS lab-vm builds may fail if the Linux guest closure is not fully substitutable"
      fi
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
    log_error "unknown method: $METHOD (expected compose, lab-vm, quadlets, or minikube)"
    exit 1
    ;;
esac

if [ "$missing" -gt 0 ]; then
  log_error "$missing required dependency check(s) failed"
  exit 1
fi

log_info "all dependencies satisfied for method=$METHOD"
