#!/usr/bin/env bash
# lab.sh — Create a virtual test lab using libvirt.
#
# Provisions an AlmaLinux 9 server VM running OpenCHAMI via RPM + quadlets
# and N client VMs that PXE boot from the server.
#
# Architecture:
#   Host (developer laptop)
#   └── libvirt
#       ├── ochami-lab-server (AlmaLinux 9 cloud image)
#       │   ├── NIC 1: default network (SSH/management from host)
#       │   ├── NIC 2: ochami-lab-net (192.168.200.0/24, serves DHCP/PXE)
#       │   ├── RPM installed, OCI images loaded into podman
#       │   └── openchami.target running
#       │
#       └── ochami-lab-client-{0..N} (empty VMs, PXE boot)
#           └── NIC: ochami-lab-net (PXE boots from server)
#
# Usage:
#   scripts/ops/lab.sh server             # Create and provision the server VM
#   scripts/ops/lab.sh clients --count 2  # Create PXE boot client VMs
#   scripts/ops/lab.sh destroy            # Tear everything down
#   scripts/ops/lab.sh status             # Show VM states and service health
#   scripts/ops/lab.sh                    # End-to-end: server + clients

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# --- Configuration (all overridable via env) ---

LAB_NETWORK_NAME="${LAB_NETWORK_NAME:-ochami-lab-net}"
LAB_NETWORK_BRIDGE="${LAB_NETWORK_BRIDGE:-virbr-lab}"
LAB_NETWORK_IP="${LAB_NETWORK_IP:-192.168.200.1}"
LAB_NETWORK_CIDR="${LAB_NETWORK_CIDR:-24}"
LAB_STATE_DIR="${LAB_STATE_DIR:-${HOME}/.local/state/openchami/lab}"

SERVER_VM_NAME="${SERVER_VM_NAME:-ochami-lab-server}"
SERVER_VM_MEMORY="${SERVER_VM_MEMORY:-6144}"
SERVER_VM_VCPUS="${SERVER_VM_VCPUS:-4}"
SERVER_VM_DISK_SIZE="${SERVER_VM_DISK_SIZE:-60G}"
SERVER_VM_USER="${SERVER_VM_USER:-almalinux}"
SERVER_VM_PASSWORD="${SERVER_VM_PASSWORD:-ochami}"

CLIENT_VM_PREFIX="${CLIENT_VM_PREFIX:-ochami-lab-client}"
CLIENT_VM_MEMORY="${CLIENT_VM_MEMORY:-2048}"
CLIENT_VM_VCPUS="${CLIENT_VM_VCPUS:-2}"
CLIENT_VM_DISK_SIZE="${CLIENT_VM_DISK_SIZE:-20G}"
CLIENT_COUNT="${CLIENT_COUNT:-2}"

ALMA_IMAGE_URL="${ALMA_IMAGE_URL:-https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2}"

OS_VARIANT="almalinux9"
SSH_TIMEOUT="${SSH_TIMEOUT:-300}"
SSH_POLL_INTERVAL="${SSH_POLL_INTERVAL:-5}"
SMD_READY_ATTEMPTS="${SMD_READY_ATTEMPTS:-60}"
SMD_READY_INTERVAL="${SMD_READY_INTERVAL:-5}"
KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"

# --- Derived paths ---

IMAGE_DIR="$LAB_STATE_DIR/images"
CLOUD_INIT_DIR="$LAB_STATE_DIR/cloud-init"
SSH_KEY_DIR="$LAB_STATE_DIR/ssh"
SSH_KEY_PATH="$SSH_KEY_DIR/id_ed25519"
SSH_PUB_KEY_PATH="$SSH_KEY_PATH.pub"
BASE_IMAGE_PATH="$IMAGE_DIR/alma-base.qcow2"
SERVER_DISK_PATH="$IMAGE_DIR/${SERVER_VM_NAME}.qcow2"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"

# --- Helpers ---

ssh_cmd() {
  local ip="$1"; shift
  ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SERVER_VM_USER@$ip" "$@"
}

scp_to() {
  local ip="$1" src="$2" dst="$3"
  scp -i "$SSH_KEY_PATH" $SSH_OPTS "$src" "$SERVER_VM_USER@$ip:$dst"
}

ensure_state_dirs() {
  mkdir -p "$IMAGE_DIR" "$CLOUD_INIT_DIR" "$SSH_KEY_DIR"
}

ensure_ssh_key() {
  if [ ! -f "$SSH_KEY_PATH" ]; then
    log_info "generating SSH key pair"
    ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY_PATH" >/dev/null
  fi
}

domain_exists() {
  virsh dominfo "$1" >/dev/null 2>&1
}

domain_state() {
  virsh domstate "$1" 2>/dev/null | tr -d '\r' | xargs
}

get_domain_ip() {
  virsh domifaddr "$1" --source lease 2>/dev/null \
    | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

wait_for_ssh() {
  local vm_name="$1"
  local elapsed=0 ip=""

  log_info "waiting for SSH on $vm_name (up to ${SSH_TIMEOUT}s)..."
  while [ "$elapsed" -lt "$SSH_TIMEOUT" ]; do
    ip="$(get_domain_ip "$vm_name" || true)"
    if [ -n "$ip" ] && ssh -i "$SSH_KEY_PATH" $SSH_OPTS \
        -o ConnectTimeout=5 "$SERVER_VM_USER@$ip" true >/dev/null 2>&1; then
      log_info "SSH ready at $SERVER_VM_USER@$ip"
      echo "$ip"
      return 0
    fi
    sleep "$SSH_POLL_INTERVAL"
    elapsed=$((elapsed + SSH_POLL_INTERVAL))
  done

  log_error "timed out waiting for SSH on $vm_name"
  return 1
}

usage() {
  cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
  server             Create and provision the server VM
  clients            Create PXE boot client VMs
  destroy            Tear everything down
  status             Show VM states and service health
  (no command)       End-to-end: server + clients

Options:
  --count N          Number of client VMs (default: $CLIENT_COUNT)
  --network          Also destroy the lab network (with destroy command)
  --profile NAME     Deployment profile (default: official)
  -h, --help         Show this help
EOF
}

# ============================================================
# Server
# ============================================================

ensure_base_image() {
  if [ -f "$BASE_IMAGE_PATH" ]; then
    log_info "base image already exists: $BASE_IMAGE_PATH"
    return 0
  fi

  log_info "downloading AlmaLinux 9 cloud image..."
  curl -fL --retry 3 --retry-delay 2 -o "$BASE_IMAGE_PATH" "$ALMA_IMAGE_URL"
  log_info "download complete"
}

ensure_server_disk() {
  if [ -f "$SERVER_DISK_PATH" ]; then
    log_info "server disk already exists: $SERVER_DISK_PATH"
    return 0
  fi

  log_info "creating overlay disk ($SERVER_VM_DISK_SIZE)"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$SERVER_DISK_PATH" "$SERVER_VM_DISK_SIZE" >/dev/null
}

write_server_cloud_init() {
  local ci_dir="$CLOUD_INIT_DIR/$SERVER_VM_NAME"
  mkdir -p "$ci_dir"

  local ssh_pub_key
  ssh_pub_key="$(cat "$SSH_PUB_KEY_PATH")"

  cat > "$ci_dir/user-data" <<EOF
#cloud-config
users:
  - name: ${SERVER_VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: ${SERVER_VM_PASSWORD}
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_pub_key}

chpasswd:
  expire: false

ssh_pwauth: true

packages:
  - podman
  - jq
  - curl

write_files:
  - path: /etc/NetworkManager/system-connections/lab-net.nmconnection
    permissions: '0600'
    content: |
      [connection]
      id=lab-net
      type=ethernet
      interface-name=eth1

      [ipv4]
      method=manual
      addresses=${LAB_NETWORK_IP}/${LAB_NETWORK_CIDR}

      [ipv6]
      method=disabled

runcmd:
  - nmcli connection reload && nmcli connection up lab-net
EOF

  cat > "$ci_dir/meta-data" <<EOF
instance-id: ${SERVER_VM_NAME}
local-hostname: ${SERVER_VM_NAME}
EOF
}

create_server_domain() {
  if domain_exists "$SERVER_VM_NAME"; then
    log_info "domain $SERVER_VM_NAME already exists"
    local state
    state="$(domain_state "$SERVER_VM_NAME")"
    if [ "$state" != "running" ]; then
      log_info "starting existing domain"
      virsh start "$SERVER_VM_NAME" >/dev/null
    fi
    return 0
  fi

  local ci_dir="$CLOUD_INIT_DIR/$SERVER_VM_NAME"

  log_info "creating VM: $SERVER_VM_NAME (${SERVER_VM_MEMORY}MiB, ${SERVER_VM_VCPUS} vCPUs)"
  virt-install \
    --name "$SERVER_VM_NAME" \
    --memory "$SERVER_VM_MEMORY" \
    --vcpus "$SERVER_VM_VCPUS" \
    --cpu host-passthrough \
    --import \
    --disk "path=$SERVER_DISK_PATH,format=qcow2,bus=virtio" \
    --network "network=default,model=virtio" \
    --network "network=$LAB_NETWORK_NAME,model=virtio" \
    --os-variant "$OS_VARIANT" \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --cloud-init "user-data=$ci_dir/user-data,meta-data=$ci_dir/meta-data,disable=on" \
    >/dev/null
  log_info "VM created"
}

build_and_install_rpm() {
  local ip="$1"

  log_info "building RPM on host..."
  env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS make -C "$PROJECT_ROOT" rpm PROFILE="${PROFILE:-official}"

  local rpm_path
  rpm_path="$(ls -t "$PROJECT_ROOT"/ochami-from-scratch-*.noarch.rpm 2>/dev/null | head -1)"
  if [ -z "$rpm_path" ]; then
    log_error "no RPM found after build"
    return 1
  fi
  log_info "built RPM: $rpm_path"

  log_info "copying RPM to VM..."
  scp_to "$ip" "$rpm_path" "~/ochami-from-scratch.rpm"

  log_info "installing RPM..."
  ssh_cmd "$ip" "sudo dnf install -y ~/ochami-from-scratch.rpm"
}

build_and_load_images() {
  local ip="$1"

  log_info "building OCI images on host..."
  env -u MAKEFLAGS -u MAKELEVEL -u MFLAGS make -C "$PROJECT_ROOT" build-images PROFILE="${PROFILE:-official}"

  local export_dir
  export_dir="$(mktemp -d)"
  trap "rm -rf '$export_dir'" RETURN

  log_info "exporting OCI images..."
  local images
  images="$(podman images --format '{{.Repository}}:{{.Tag}}' | grep '^localhost/' || true)"
  if [ -z "$images" ]; then
    log_warn "no localhost/* images found to export"
    return 0
  fi

  while IFS= read -r image; do
    local name
    name="$(echo "$image" | sed 's|^localhost/||; s|:|_|g')"
    log_info "exporting $image..."
    podman save "$image" | gzip > "$export_dir/${name}.tar.gz"
  done <<< "$images"

  log_info "loading OCI images on VM..."
  "$SCRIPT_DIR/load-images.sh" \
    --remote "$SERVER_VM_USER@$ip" \
    --ssh-key "$SSH_KEY_PATH" \
    "$export_dir"
}

start_server_services() {
  local ip="$1"

  log_info "starting openchami.target..."
  ssh_cmd "$ip" "sudo systemctl start openchami.target"

  log_info "waiting for services to come up..."
  local attempts=0
  while [ "$attempts" -lt "$SMD_READY_ATTEMPTS" ]; do
    if ssh_cmd "$ip" "curl -sfk https://localhost:27779/hsm/v2/service/ready >/dev/null 2>&1"; then
      log_info "SMD is ready"
      return 0
    fi
    sleep "$SMD_READY_INTERVAL"
    attempts=$((attempts + 1))
  done

  log_warn "SMD did not become ready within $((SMD_READY_ATTEMPTS * SMD_READY_INTERVAL))s"
  log_warn "check service status with: ssh -i $SSH_KEY_PATH $SERVER_VM_USER@$ip 'sudo systemctl list-units openchami-*'"
}

build_and_transfer_boot_artifacts() {
  local ip="$1"

  log_info "building boot artifacts on host..."
  "$SCRIPT_DIR/build-boot-artifacts.sh"

  local artifacts_dir="${PROJECT_ROOT}/.tmp/boot-artifacts"
  if [ ! -d "$artifacts_dir" ]; then
    log_error "boot artifacts directory not found: $artifacts_dir"
    return 1
  fi

  log_info "transferring boot artifacts to VM..."
  ssh_cmd "$ip" "sudo mkdir -p /etc/openchami/artifacts"
  # Use a tarball to preserve directory structure
  tar -cf - -C "$artifacts_dir" . \
    | ssh -i "$SSH_KEY_PATH" $SSH_OPTS "$SERVER_VM_USER@$ip" \
        "sudo tar -xf - -C /etc/openchami/artifacts/"
  log_info "boot artifacts transferred"
}

register_server_bss_defaults() {
  local ip="$1"

  log_info "registering BSS defaults on VM..."
  ssh_cmd "$ip" "sudo /usr/libexec/openchami/register-bss-defaults.sh" || {
    log_warn "register-bss-defaults.sh not found or failed; attempting manual registration"
    # Fall back to running the local script via SSH
    ssh_cmd "$ip" "bash -s" < "$SCRIPT_DIR/register-bss-defaults.sh" || {
      log_warn "BSS default registration failed"
    }
  }
}

print_server_summary() {
  local ip="$1"
  cat >&2 <<EOF

============================================================
  OpenCHAMI Lab Server Ready
============================================================

  VM name:    $SERVER_VM_NAME
  IP:         $ip
  User:       $SERVER_VM_USER
  Password:   $SERVER_VM_PASSWORD

  SSH:        ssh -i $SSH_KEY_PATH $SERVER_VM_USER@$ip
  Console:    virsh console $SERVER_VM_NAME

  Lab network: $LAB_NETWORK_NAME ($LAB_NETWORK_IP/$LAB_NETWORK_CIDR)

  Services (via SSH tunnel or from VM):
    SMD         https://localhost:27779/hsm/v2/service/ready
    BSS         http://localhost:27778/boot/v1/bootparameters
    Cloud-init  http://localhost:27777/cloud-init
    PCS         http://localhost:28007

============================================================
EOF
}

lab_server() {
  require_command virsh "libvirt management"
  require_command virt-install "VM creation"
  require_command qemu-img "disk image management"
  require_command curl "HTTP requests"
  require_command ssh "remote access"
  require_command ssh-keygen "SSH key generation"
  require_command podman "OCI image management"
  require_command make "build system"

  ensure_state_dirs
  ensure_ssh_key

  # 1. Ensure lab network (no DHCP -- the server VM provides DHCP)
  ensure_libvirt_network "$LAB_NETWORK_NAME" "$LAB_NETWORK_BRIDGE" "$LAB_NETWORK_IP" "$LAB_NETWORK_CIDR"
  ensure_bridge_carrier "$LAB_NETWORK_BRIDGE"

  # 2-4. Download image, create disk, generate cloud-init
  ensure_base_image
  ensure_server_disk
  write_server_cloud_init

  # 5. Create VM with two NICs
  create_server_domain

  # 6. Wait for SSH
  local server_ip
  server_ip="$(wait_for_ssh "$SERVER_VM_NAME")"

  # 7. Build and install RPM
  build_and_install_rpm "$server_ip"

  # 8-9. Build, export, and load OCI images
  build_and_load_images "$server_ip"

  # 10. Start services
  start_server_services "$server_ip"

  # 11. Build and transfer boot artifacts
  build_and_transfer_boot_artifacts "$server_ip"

  # 12. Register BSS defaults
  register_server_bss_defaults "$server_ip"

  # 13. Print summary
  print_server_summary "$server_ip"
}

# ============================================================
# Clients
# ============================================================

get_server_ip() {
  if ! domain_exists "$SERVER_VM_NAME"; then
    log_error "server VM $SERVER_VM_NAME does not exist; run '$0 server' first"
    return 1
  fi

  local state
  state="$(domain_state "$SERVER_VM_NAME")"
  if [ "$state" != "running" ]; then
    log_error "server VM $SERVER_VM_NAME is not running (state: $state)"
    return 1
  fi

  local ip
  ip="$(get_domain_ip "$SERVER_VM_NAME")"
  if [ -z "$ip" ]; then
    log_error "could not determine server VM IP"
    return 1
  fi

  echo "$ip"
}

mac_for_client() {
  local idx="$1"
  printf '52:54:00:1a:b0:%02x\n' "$idx"
}

ip_for_client() {
  local idx="$1"
  printf '192.168.200.%d\n' "$((100 + idx))"
}

xname_for_client() {
  local idx="$1"
  printf 'x1000c0s0b%dn0\n' "$idx"
}

lab_clients() {
  local count="$CLIENT_COUNT"

  require_command virsh "libvirt management"
  require_command virt-install "VM creation"
  require_command qemu-img "disk image management"
  require_command curl "HTTP requests"

  ensure_state_dirs

  # 1. Verify server is running
  local server_ip
  server_ip="$(get_server_ip)"
  log_info "server VM is running at $server_ip"

  # 2. Create client VMs
  local idx mac client_ip xname client_name disk_path
  for idx in $(seq 0 $((count - 1))); do
    mac="$(mac_for_client "$idx")"
    client_ip="$(ip_for_client "$idx")"
    xname="$(xname_for_client "$idx")"
    client_name="${CLIENT_VM_PREFIX}-${idx}"
    disk_path="$IMAGE_DIR/${client_name}.qcow2"

    log_info "--- client $idx: $client_name ($xname, $mac, $client_ip) ---"

    # Create empty qcow2 disk
    if [ ! -f "$disk_path" ]; then
      log_info "creating client disk ($CLIENT_VM_DISK_SIZE)"
      qemu-img create -f qcow2 "$disk_path" "$CLIENT_VM_DISK_SIZE" >/dev/null
    fi

    # Create VM if it doesn't exist
    if ! domain_exists "$client_name"; then
      log_info "creating client VM: $client_name"
      virt-install \
        --name "$client_name" \
        --memory "$CLIENT_VM_MEMORY" \
        --vcpus "$CLIENT_VM_VCPUS" \
        --cpu host-passthrough \
        --disk "path=$disk_path,format=qcow2,bus=virtio" \
        --network "network=$LAB_NETWORK_NAME,model=virtio,mac=$mac" \
        --boot network,hd \
        --osinfo detect=on,require=off \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        >/dev/null
      log_info "client VM $client_name created"
    else
      log_info "client VM $client_name already exists"
      local state
      state="$(domain_state "$client_name")"
      if [ "$state" != "running" ]; then
        log_info "starting client VM $client_name"
        virsh start "$client_name" >/dev/null 2>&1 || true
      fi
    fi

    # Register node in SMD via SSH to server
    log_info "registering $xname in SMD..."
    ssh_cmd "$server_ip" "curl -skf -X POST https://localhost:27779/hsm/v2/Inventory/EthernetInterfaces \
      -H 'Content-Type: application/json' \
      -d '{
        \"ComponentID\": \"$xname\",
        \"Description\": \"Ethernet Interface\",
        \"MACAddress\": \"$mac\",
        \"IPAddresses\": [{\"IPAddress\": \"$client_ip\"}]
      }'" || log_warn "ethernet interface registration for $xname may already exist"

    ssh_cmd "$server_ip" "curl -skf -X POST https://localhost:27779/hsm/v2/State/Components \
      -H 'Content-Type: application/json' \
      -d '{
        \"Components\": [{
          \"ID\": \"$xname\",
          \"State\": \"Ready\",
          \"NetType\": \"Sling\",
          \"Arch\": \"X86\",
          \"Role\": \"Compute\"
        }]
      }'" || log_warn "component registration for $xname may already exist"
  done

  # Trigger kea-sync
  log_info "triggering kea-sync reconciliation..."
  ssh_cmd "$server_ip" "curl -sf -X POST http://localhost:${KEA_SYNC_PORT}/v1/sync" || \
    log_warn "kea-sync trigger failed; DHCP leases may not be updated"

  # Print summary
  cat >&2 <<EOF

============================================================
  OpenCHAMI Lab Clients Created
============================================================

EOF
  for idx in $(seq 0 $((count - 1))); do
    local cname="${CLIENT_VM_PREFIX}-${idx}"
    local cxname
    cxname="$(xname_for_client "$idx")"
    printf '  %-30s %s\n' "$cname" "$cxname" >&2
  done
  cat >&2 <<EOF

  Watch a client console:
    virsh console ${CLIENT_VM_PREFIX}-0

  Clients PXE boot from the server at $LAB_NETWORK_IP.

============================================================
EOF
}

# ============================================================
# Destroy
# ============================================================

lab_destroy() {
  local destroy_network="false"

  for arg in "$@"; do
    case "$arg" in
      --network) destroy_network="true" ;;
    esac
  done

  # Destroy client VMs
  log_info "destroying client VMs..."
  local domains
  domains="$(virsh list --all --name 2>/dev/null | grep "^${CLIENT_VM_PREFIX}-" || true)"
  if [ -n "$domains" ]; then
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      log_info "destroying client VM: $domain"
      virsh destroy "$domain" >/dev/null 2>&1 || true
      virsh undefine "$domain" >/dev/null 2>&1 || true
    done <<< "$domains"
  else
    log_info "no client VMs found"
  fi

  # Destroy server VM
  if domain_exists "$SERVER_VM_NAME"; then
    log_info "destroying server VM: $SERVER_VM_NAME"
    virsh destroy "$SERVER_VM_NAME" >/dev/null 2>&1 || true
    virsh undefine "$SERVER_VM_NAME" >/dev/null 2>&1 || true
  else
    log_info "server VM $SERVER_VM_NAME does not exist"
  fi

  # Clean up disks and state
  if [ -d "$LAB_STATE_DIR" ]; then
    log_info "cleaning up state directory: $LAB_STATE_DIR"
    rm -rf "${LAB_STATE_DIR:?}/images"
    rm -rf "${LAB_STATE_DIR:?}/cloud-init"
    # Keep SSH keys unless the directory is completely empty
  fi

  # Optionally destroy lab network
  if [ "$destroy_network" = "true" ]; then
    log_info "destroying lab network: $LAB_NETWORK_NAME"
    sudo -n virsh net-destroy "$LAB_NETWORK_NAME" >/dev/null 2>&1 || true
    sudo -n virsh net-undefine "$LAB_NETWORK_NAME" >/dev/null 2>&1 || true
    # Clean up dummy interface
    remove_bridge_carrier_dummy "ochami-lab0" || true
  fi

  log_info "lab teardown complete"
}

# ============================================================
# Status
# ============================================================

lab_status() {
  local server_state="not defined"
  local server_ip=""

  # Server VM state
  if domain_exists "$SERVER_VM_NAME"; then
    server_state="$(domain_state "$SERVER_VM_NAME")"
    server_ip="$(get_domain_ip "$SERVER_VM_NAME" || true)"
  fi

  cat >&2 <<EOF

============================================================
  OpenCHAMI Lab Status
============================================================

  Server:
    VM:     $SERVER_VM_NAME
    State:  $server_state
    IP:     ${server_ip:-n/a}
EOF

  # Check services if server is running
  if [ "$server_state" = "running" ] && [ -n "$server_ip" ] && [ -f "$SSH_KEY_PATH" ]; then
    local target_state smd_ready components
    target_state="$(ssh_cmd "$server_ip" "systemctl is-active openchami.target 2>/dev/null" 2>/dev/null || echo "unknown")"
    smd_ready="$(ssh_cmd "$server_ip" "curl -sfk https://localhost:27779/hsm/v2/service/ready >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "unknown")"
    components="$(ssh_cmd "$server_ip" "curl -sfk https://localhost:27779/hsm/v2/State/Components 2>/dev/null | jq -r '.Components[]?.ID' 2>/dev/null" 2>/dev/null || true)"

    cat >&2 <<EOF

  Services:
    openchami.target: $target_state
    SMD ready:        $smd_ready
EOF

    if [ -n "$components" ]; then
      printf '\n  Registered components:\n' >&2
      while IFS= read -r comp; do
        printf '    - %s\n' "$comp" >&2
      done <<< "$components"
    fi

    cat >&2 <<EOF

  SSH: ssh -i $SSH_KEY_PATH $SERVER_VM_USER@$server_ip
EOF
  fi

  # Client VMs
  printf '\n  Clients:\n' >&2
  local found_clients=false
  local domains
  domains="$(virsh list --all --name 2>/dev/null | grep "^${CLIENT_VM_PREFIX}-" || true)"
  if [ -n "$domains" ]; then
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      found_clients=true
      local cstate
      cstate="$(domain_state "$domain")"
      printf '    %-30s %s\n' "$domain" "$cstate" >&2
    done <<< "$domains"
  fi

  if [ "$found_clients" = "false" ]; then
    printf '    (none)\n' >&2
  fi

  printf '\n============================================================\n\n' >&2
}

# ============================================================
# Main
# ============================================================

ACTION=""
DESTROY_ARGS=()

parse_lab_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      server)
        ACTION="server"
        shift
        ;;
      clients)
        ACTION="clients"
        shift
        ;;
      destroy)
        ACTION="destroy"
        shift
        ;;
      status)
        ACTION="status"
        shift
        ;;
      --count)
        CLIENT_COUNT="$2"
        shift 2
        ;;
      --count=*)
        CLIENT_COUNT="${1#--count=}"
        shift
        ;;
      --network)
        DESTROY_ARGS+=("--network")
        shift
        ;;
      --profile)
        PROFILE="$2"
        shift 2
        ;;
      --profile=*)
        PROFILE="${1#--profile=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_lab_args "$@"

  case "${ACTION:-}" in
    server)
      lab_server
      ;;
    clients)
      lab_clients
      ;;
    destroy)
      lab_destroy "${DESTROY_ARGS[@]+"${DESTROY_ARGS[@]}"}"
      ;;
    status)
      lab_status
      ;;
    "")
      # End-to-end: server + clients
      lab_server
      lab_clients
      ;;
    *)
      log_error "unknown action: $ACTION"
      usage
      exit 1
      ;;
  esac
}

main "$@"
