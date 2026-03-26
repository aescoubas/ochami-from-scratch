#!/usr/bin/env bash
# lab-setup.sh — Set up libvirt network and VMs for the OpenCHAMI lab.
# Usage: ./lab-setup.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

parse_common_args "$@"

NETWORK_NAME="${NETWORK_NAME:-ochami-pxe-net}"
NETWORK_BRIDGE="${NETWORK_BRIDGE:-virbr-ochami}"
NETWORK_CIDR="${NETWORK_CIDR:-24}"
CONTROLLER_IP="${CONTROLLER_IP:-192.168.100.1}"
CONTROLLER_VM="${CONTROLLER_VM:-ochami-controller}"
BOOT_NODE_VM="${BOOT_NODE_VM:-ochami-boot-node}"

# --- Network setup ---

setup_network() {
  log_info "ensuring libvirt PXE network: $NETWORK_NAME"
  ensure_libvirt_network "$NETWORK_NAME" "$NETWORK_BRIDGE" "$CONTROLLER_IP" "$NETWORK_CIDR"
}

# --- VM creation ---

create_controller_vm() {
  log_info "creating controller VM: $CONTROLLER_VM"
  if virsh dominfo "$CONTROLLER_VM" >/dev/null 2>&1; then
    log_info "VM $CONTROLLER_VM already exists"
    return 0
  fi

  log_info "controller VM creation is handled by the deployment method (compose, quadlets, etc.)"
  log_info "use: make deploy METHOD=compose to deploy the stack on the host"
}

# --- Teardown ---

teardown_lab() {
  log_info "tearing down lab..."
  for vm in "$CONTROLLER_VM" "$BOOT_NODE_VM"; do
    if virsh dominfo "$vm" >/dev/null 2>&1; then
      run_cmd sudo virsh destroy "$vm" 2>/dev/null || true
      run_cmd sudo virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
      log_info "removed VM: $vm"
    fi
  done

  if virsh net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    run_cmd sudo virsh net-destroy "$NETWORK_NAME" 2>/dev/null || true
    run_cmd sudo virsh net-undefine "$NETWORK_NAME" 2>/dev/null || true
    log_info "removed network: $NETWORK_NAME"
  fi
}

# --- Main ---

ACTION="${1:-setup}"
case "$ACTION" in
  setup|--dry-run)
    require_command virsh "libvirt management"
    setup_network
    create_controller_vm
    ;;
  teardown)
    teardown_lab
    ;;
  *)
    log_error "usage: $0 [setup|teardown] [--dry-run]"
    exit 1
    ;;
esac
