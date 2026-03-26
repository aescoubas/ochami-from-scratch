#!/usr/bin/env bash
# create-demo-vm.sh — Create a libvirt VM with the OpenCHAMI RPM pre-installed.
#
# Downloads an AlmaLinux 9 cloud image, creates a VM, copies in the RPM and
# the ochami CLI, installs both, and starts the openchami.target.
#
# Usage:
#   ./create-demo-vm.sh
#   ./create-demo-vm.sh --rpm path/to/ochami-from-scratch.rpm --cli path/to/ochami
#   ./create-demo-vm.sh --destroy
#
# The VM is accessible via:
#   ssh -i <state-dir>/ssh/id_ed25519 almalinux@<vm-ip>
#   virsh console openchami-demo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Defaults ---
VM_NAME="${DEMO_VM_NAME:-openchami-demo}"
VM_MEMORY="${DEMO_VM_MEMORY:-4096}"
VM_VCPUS="${DEMO_VM_VCPUS:-2}"
VM_DISK_SIZE="${DEMO_VM_DISK_SIZE:-20G}"
LIBVIRT_NETWORK="${DEMO_VM_NETWORK:-default}"
STATE_DIR="${DEMO_VM_STATE_DIR:-${HOME}/.local/state/openchami/demo}"
VM_USER="almalinux"
VM_PASSWORD="ochami"
OS_VARIANT="almalinux9"

ALMA_IMAGE_URL="${DEMO_ALMA_IMAGE_URL:-https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2}"

RPM_PATH=""
CLI_PATH=""
ACTION="create"

SSH_TIMEOUT=300
SSH_POLL_INTERVAL=5

# --- Paths derived from state dir ---
IMAGE_DIR="$STATE_DIR/images"
CLOUD_INIT_DIR="$STATE_DIR/cloud-init/$VM_NAME"
SSH_KEY_DIR="$STATE_DIR/ssh"
SSH_KEY_PATH="$SSH_KEY_DIR/id_ed25519"
SSH_PUB_KEY_PATH="$SSH_KEY_PATH.pub"
BASE_IMAGE_PATH="$IMAGE_DIR/alma-base.qcow2"
DOMAIN_DISK_PATH="$IMAGE_DIR/${VM_NAME}.qcow2"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"

log() { echo "[demo-vm] $*" >&2; }

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Create and provision an OpenCHAMI demo VM.

Options:
  --rpm PATH       Path to the ochami-from-scratch RPM (auto-detected if omitted)
  --cli PATH       Path to the ochami CLI binary (auto-detected if omitted)
  --name NAME      VM name (default: openchami-demo)
  --destroy        Tear down the demo VM
  -h, --help       Show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --rpm)      RPM_PATH="$2"; shift 2 ;;
      --cli)      CLI_PATH="$2"; shift 2 ;;
      --name)     VM_NAME="$2"; shift 2 ;;
      --destroy)  ACTION="destroy"; shift ;;
      -h|--help)  usage; exit 0 ;;
      *)          log "unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR: required command not found: $1"
    exit 1
  fi
}

check_prerequisites() {
  require_command virsh
  require_command virt-install
  require_command qemu-img
  require_command curl
  require_command ssh
  require_command ssh-keygen
}

auto_detect_rpm() {
  if [ -n "$RPM_PATH" ]; then return 0; fi

  local found
  found="$(ls -t "$PROJECT_ROOT"/ochami-from-scratch-*.noarch.rpm 2>/dev/null | head -1)"
  if [ -n "$found" ]; then
    RPM_PATH="$found"
    log "auto-detected RPM: $RPM_PATH"
  else
    log "ERROR: no RPM found — build one with 'make rpm PROFILE=cscs' or pass --rpm"
    exit 1
  fi
}

auto_detect_cli() {
  if [ -n "$CLI_PATH" ]; then return 0; fi

  # Check common locations
  local candidates=(
    "$PROJECT_ROOT/../../shared/ochami-cli/ochami"
    "$(command -v ochami 2>/dev/null || true)"
  )
  for c in "${candidates[@]}"; do
    if [ -n "$c" ] && [ -x "$c" ]; then
      CLI_PATH="$c"
      log "auto-detected CLI: $CLI_PATH"
      return 0
    fi
  done

  log "WARNING: ochami CLI not found — skipping CLI install"
  log "  Build it with: cd shared/ochami-cli && make"
  CLI_PATH=""
}

ensure_state_dirs() {
  mkdir -p "$IMAGE_DIR" "$CLOUD_INIT_DIR" "$SSH_KEY_DIR"
}

ensure_ssh_key() {
  if [ ! -f "$SSH_KEY_PATH" ]; then
    log "generating SSH key pair"
    ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY_PATH" >/dev/null
  fi
}

ensure_base_image() {
  if [ -f "$BASE_IMAGE_PATH" ]; then
    log "base image already exists: $BASE_IMAGE_PATH"
    return 0
  fi

  log "downloading AlmaLinux 9 cloud image..."
  curl -fL --retry 3 --retry-delay 2 -o "$BASE_IMAGE_PATH" "$ALMA_IMAGE_URL"
  log "download complete"
}

ensure_domain_disk() {
  if [ -f "$DOMAIN_DISK_PATH" ]; then
    log "domain disk already exists: $DOMAIN_DISK_PATH"
    return 0
  fi

  log "creating overlay disk ($VM_DISK_SIZE)"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$DOMAIN_DISK_PATH" "$VM_DISK_SIZE" >/dev/null
}

write_cloud_init() {
  local ssh_pub_key
  ssh_pub_key="$(cat "$SSH_PUB_KEY_PATH")"

  cat > "$CLOUD_INIT_DIR/user-data" <<EOF
#cloud-config
users:
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: ${VM_PASSWORD}
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_pub_key}

chpasswd:
  expire: false

ssh_pwauth: true
EOF

  cat > "$CLOUD_INIT_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF
}

domain_exists() {
  virsh dominfo "$VM_NAME" >/dev/null 2>&1
}

create_domain() {
  if domain_exists; then
    log "domain $VM_NAME already exists"
    local state
    state="$(virsh domstate "$VM_NAME" 2>/dev/null | tr -d '\r' | xargs)"
    if [ "$state" != "running" ]; then
      log "starting existing domain"
      virsh start "$VM_NAME" >/dev/null
    fi
    return 0
  fi

  log "creating VM: $VM_NAME (${VM_MEMORY}MiB, ${VM_VCPUS} vCPUs)"
  virt-install \
    --name "$VM_NAME" \
    --memory "$VM_MEMORY" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --import \
    --disk "path=$DOMAIN_DISK_PATH,format=qcow2,bus=virtio" \
    --network "network=$LIBVIRT_NETWORK,model=virtio" \
    --os-variant "$OS_VARIANT" \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --cloud-init "user-data=$CLOUD_INIT_DIR/user-data,meta-data=$CLOUD_INIT_DIR/meta-data,disable=on" \
    >/dev/null
  log "VM created"
}

get_domain_ip() {
  virsh domifaddr "$VM_NAME" --source lease 2>/dev/null \
    | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

wait_for_ssh() {
  local elapsed=0 ip=""

  log "waiting for SSH (up to ${SSH_TIMEOUT}s)..."
  while [ "$elapsed" -lt "$SSH_TIMEOUT" ]; do
    ip="$(get_domain_ip || true)"
    if [ -n "$ip" ] && ssh -i "$SSH_KEY_PATH" $SSH_OPTS \
        -o ConnectTimeout=5 "$VM_USER@$ip" true >/dev/null 2>&1; then
      log "SSH ready at $VM_USER@$ip"
      echo "$ip"
      return 0
    fi
    sleep "$SSH_POLL_INTERVAL"
    elapsed=$((elapsed + SSH_POLL_INTERVAL))
  done

  log "ERROR: timed out waiting for SSH on $VM_NAME"
  return 1
}

ssh_cmd() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$VM_USER@$ip" "$@"
}

scp_to() {
  local ip="$1" src="$2" dst="$3"
  scp -i "$SSH_KEY_PATH" $SSH_OPTS "$src" "$VM_USER@$ip:$dst"
}

install_rpm() {
  local ip="$1"

  log "copying RPM to VM..."
  scp_to "$ip" "$RPM_PATH" "~/ochami-from-scratch.rpm"

  log "installing RPM..."
  ssh_cmd "$ip" "sudo dnf install -y ~/ochami-from-scratch.rpm"
}

install_cli() {
  local ip="$1"

  if [ -z "$CLI_PATH" ]; then return 0; fi

  log "copying ochami CLI to VM..."
  scp_to "$ip" "$CLI_PATH" "~/ochami"
  ssh_cmd "$ip" "sudo install -m 755 ~/ochami /usr/local/bin/ochami"

  # Write default config
  log "configuring ochami CLI..."
  ssh_cmd "$ip" 'mkdir -p ~/.config/ochami && cat > ~/.config/ochami/config.yaml' <<'YAML'
log:
  level: warning
  format: basic

default-cluster: local

clusters:
  - name: local
    cluster:
      smd:
        uri: https://localhost:27779/hsm/v2
      bss:
        uri: http://localhost:27778/boot/v1
      cloud-init:
        uri: http://localhost:27777/cloud-init
      pcs:
        uri: http://localhost:28007
YAML
}

start_services() {
  local ip="$1"

  log "starting openchami.target..."
  ssh_cmd "$ip" "sudo systemctl start openchami.target"

  log "waiting for services to come up (this may take a minute on first pull)..."
  local attempts=0 max_attempts=60
  while [ $attempts -lt $max_attempts ]; do
    if ssh_cmd "$ip" "curl -sfk https://localhost:27779/hsm/v2/service/ready >/dev/null 2>&1"; then
      log "SMD is ready"
      break
    fi
    sleep 5
    attempts=$((attempts + 1))
  done

  if [ $attempts -eq $max_attempts ]; then
    log "WARNING: SMD did not become ready within $((max_attempts * 5))s"
    log "check service status with: ssh $VM_USER@$ip 'sudo systemctl list-units openchami-*'"
  fi
}

print_summary() {
  local ip="$1"
  cat >&2 <<EOF

============================================================
  OpenCHAMI Demo VM Ready
============================================================

  VM name:    $VM_NAME
  IP:         $ip
  User:       $VM_USER
  Password:   $VM_PASSWORD

  SSH:        ssh -i $SSH_KEY_PATH $VM_USER@$ip
  Console:    virsh console $VM_NAME

  Services:
    SMD         http://$ip:27779/hsm/v2/service/ready
    BSS         http://$ip:27778/boot/v1/bootparameters
    Cloud-init  http://$ip:27777/cloud-init
    PCS         http://$ip:28007

  CLI (inside VM):
    ochami smd service status --no-token
    ochami smd component get --no-token

  Teardown:
    $0 --destroy

============================================================
EOF
}

destroy() {
  log "destroying VM: $VM_NAME"
  if domain_exists; then
    virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    virsh undefine "$VM_NAME" >/dev/null 2>&1 || true
  fi
  rm -f "$DOMAIN_DISK_PATH"
  rm -rf "$CLOUD_INIT_DIR"
  log "done"
}

main() {
  parse_args "$@"

  if [ "$ACTION" = "destroy" ]; then
    destroy
    return 0
  fi

  check_prerequisites
  auto_detect_rpm
  auto_detect_cli
  ensure_state_dirs
  ensure_ssh_key
  ensure_base_image
  ensure_domain_disk
  write_cloud_init
  create_domain

  local vm_ip
  vm_ip="$(wait_for_ssh)"

  install_rpm "$vm_ip"
  install_cli "$vm_ip"
  start_services "$vm_ip"
  print_summary "$vm_ip"
}

main "$@"
