#!/usr/bin/env bash
# test-packages.sh — Spin up AlmaLinux/Ubuntu VMs, install RPM/DEB, verify quadlet deployment.
#
# Usage:
#   scripts/ops/test-packages.sh --distro alma|ubuntu [--destroy]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
. "$SCRIPT_DIR/lib/common.sh"
NIX_FLAKE_REF="${OPENCHAMI_NIX_FLAKE_REF:-$(nix_flake_ref "$PROJECT_ROOT")}"

DISTRO=""
ACTION="test"
TEST_NODE_IMAGE="${TEST_NODE_IMAGE:-nixos}"
TEST_NODE_IMAGE="${OPENCHAMI_TEST_NODE_IMAGE:-$TEST_NODE_IMAGE}"
export OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE"

# Cloud image URLs
ALMA_IMAGE_URL="${ALMA_IMAGE_URL:-https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2}"
UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"

# State directory
DEFAULT_STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/openchami/pkg-test"
STATE_DIR="${PKG_TEST_STATE_DIR:-${DEFAULT_STATE_DIR}}"
IMAGE_DIR="${STATE_DIR}/images"
SSH_KEY_DIR="${STATE_DIR}/ssh"

# VM sizing
VM_MEMORY_MIB="${PKG_TEST_VM_MEMORY_MIB:-4096}"
VM_VCPUS="${PKG_TEST_VM_VCPUS:-2}"
VM_DISK_SIZE="${PKG_TEST_VM_DISK_SIZE:-20G}"

# Port allocation (distinct from lab-vm to allow coexistence)
ALMA_SSH_PORT=10322
ALMA_HTTP_PORT=28300
ALMA_BSS_PORT=29878
ALMA_SMD_PORT=29879
UBUNTU_SSH_PORT=10422
UBUNTU_HTTP_PORT=28400
UBUNTU_BSS_PORT=29978
UBUNTU_SMD_PORT=29979

# Libvirt
PXE_NETWORK_NAME="${PKG_TEST_PXE_NETWORK:-openchami-lab-net}"

SSH_TIMEOUT_SECONDS="${SSH_TIMEOUT_SECONDS:-600}"
SSH_POLL_INTERVAL_SECONDS="${SSH_POLL_INTERVAL_SECONDS:-5}"
SSH_KEY_PATH=""
SSH_PUB_KEY_PATH=""

usage() {
  cat <<USAGE
Usage:
  $0 --distro alma|ubuntu
  $0 --distro alma|ubuntu --destroy

Options:
  --distro DISTRO   Guest distro (alma|ubuntu)
  --destroy         Destroy the selected distro VM and clean up
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --distro)
      DISTRO="${2:-}"
      shift 2
      ;;
    --distro=*)
      DISTRO="${1#--distro=}"
      shift
      ;;
    --destroy)
      ACTION="destroy"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$DISTRO" ]; then
  log_error "--distro is required (alma|ubuntu)"
  usage
  exit 1
fi

# --- Distro-specific configuration ---

DOMAIN_NAME=""
VM_USER=""
BASE_IMAGE_URL=""
SSH_PORT=""
HTTP_PORT=""
BSS_PORT=""
SMD_PORT=""
PKG_TYPE=""

case "$DISTRO" in
  alma)
    DOMAIN_NAME="openchami-pkg-alma9"
    VM_USER="almalinux"
    BASE_IMAGE_URL="$ALMA_IMAGE_URL"
    SSH_PORT="$ALMA_SSH_PORT"
    HTTP_PORT="$ALMA_HTTP_PORT"
    BSS_PORT="$ALMA_BSS_PORT"
    SMD_PORT="$ALMA_SMD_PORT"
    PKG_TYPE="rpm"
    ;;
  ubuntu)
    DOMAIN_NAME="openchami-pkg-ubuntu2404"
    VM_USER="ubuntu"
    BASE_IMAGE_URL="$UBUNTU_IMAGE_URL"
    SSH_PORT="$UBUNTU_SSH_PORT"
    HTTP_PORT="$UBUNTU_HTTP_PORT"
    BSS_PORT="$UBUNTU_BSS_PORT"
    SMD_PORT="$UBUNTU_SMD_PORT"
    PKG_TYPE="deb"
    ;;
  *)
    log_error "unsupported distro: $DISTRO (use alma or ubuntu)"
    exit 1
    ;;
esac

BASE_IMAGE_PATH="${IMAGE_DIR}/${DISTRO}-base.qcow2"
DOMAIN_DISK_PATH="${IMAGE_DIR}/${DOMAIN_NAME}.qcow2"
CLOUD_INIT_DIR="${STATE_DIR}/cloud-init/${DOMAIN_NAME}"
USER_DATA_PATH="${CLOUD_INIT_DIR}/user-data"
META_DATA_PATH="${CLOUD_INIT_DIR}/meta-data"
SHARED_DIR="${STATE_DIR}/shared/${DOMAIN_NAME}"

# --- Helpers ---

ensure_state_dirs() {
  mkdir -p "$IMAGE_DIR" "$SSH_KEY_DIR" "$CLOUD_INIT_DIR" "$SHARED_DIR"
}

ensure_ssh_key() {
  SSH_KEY_PATH="${SSH_KEY_DIR}/id_ed25519"
  SSH_PUB_KEY_PATH="${SSH_KEY_PATH}.pub"

  if [ ! -f "$SSH_KEY_PATH" ]; then
    log_info "generating dedicated SSH key for package test guests"
    ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY_PATH" >/dev/null
  fi
}

ssh_cmd() {
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o LogLevel=ERROR -o ConnectTimeout=10 \
    -i "$SSH_KEY_PATH" -p "$SSH_PORT" \
    "${VM_USER}@127.0.0.1" "$@"
}

scp_to_vm() {
  scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o IdentitiesOnly=yes -o LogLevel=ERROR -o ConnectTimeout=10 \
    -i "$SSH_KEY_PATH" -P "$SSH_PORT" \
    "$1" "${VM_USER}@127.0.0.1:$2"
}

ensure_base_image() {
  if [ -f "$BASE_IMAGE_PATH" ]; then
    return 0
  fi

  log_info "downloading base image for $DISTRO"
  curl -fL --retry 3 --retry-delay 2 -o "$BASE_IMAGE_PATH" "$BASE_IMAGE_URL"
}

ensure_domain_disk() {
  if [ -f "$DOMAIN_DISK_PATH" ]; then
    return 0
  fi

  log_info "creating overlay disk: $DOMAIN_DISK_PATH"
  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$DOMAIN_DISK_PATH" "$VM_DISK_SIZE" >/dev/null
}

domain_exists() {
  sudo -n virsh dominfo "$DOMAIN_NAME" >/dev/null 2>&1
}

domain_is_running() {
  local state
  state="$(sudo -n virsh domstate "$DOMAIN_NAME" 2>/dev/null | tr -d '\r' | xargs)"
  [ "$state" = "running" ]
}

# --- Build packages ---

build_packages() {
  log_info "building RPM/DEB packages via nix"
  local pkg_out
  pkg_out="$(OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE" nix build --impure "${NIX_FLAKE_REF}#packages" --no-link --print-out-paths)"
  log_info "packages built: $pkg_out"

  # Copy the relevant package to the shared directory (remove stale read-only copies first)
  rm -f "$SHARED_DIR"/*.rpm "$SHARED_DIR"/*.deb 2>/dev/null || true
  if [ "$PKG_TYPE" = "rpm" ]; then
    cp "$pkg_out"/*.rpm "$SHARED_DIR"/
    chmod u+w "$SHARED_DIR"/*.rpm
    PACKAGE_FILE="$(ls "$SHARED_DIR"/*.rpm | head -n1)"
  else
    cp "$pkg_out"/*.deb "$SHARED_DIR"/
    chmod u+w "$SHARED_DIR"/*.deb
    PACKAGE_FILE="$(ls "$SHARED_DIR"/*.deb | head -n1)"
  fi
  log_info "package ready: $PACKAGE_FILE"
}

# --- Cloud-init ---

write_cloud_init() {
  local ssh_pub_key
  ssh_pub_key="$(cat "$SSH_PUB_KEY_PATH")"

  # Distro-specific package install commands.
  # Also configure eth1 (PXE NIC) with a static IP via runcmd instead of
  # network-config, so we don't break passt's DHCP/DNS on the management NIC.
  local install_cmds=""
  if [ "$PKG_TYPE" = "rpm" ]; then
    install_cmds="
  - dnf install -y podman gettext systemd
  - systemctl enable --now podman.socket
  - ip addr add 192.168.100.1/24 dev eth1 2>/dev/null || true
  - ip link set eth1 up"
  else
    install_cmds="
  - apt-get update -y
  - apt-get install -y podman gettext-base systemd
  - systemctl enable --now podman.socket
  - ip addr add 192.168.100.1/24 dev eth1 2>/dev/null || true
  - ip link set eth1 up"
  fi

  cat > "$USER_DATA_PATH" <<EOF_USER_DATA
#cloud-config
package_update: true
package_upgrade: false
ssh_pwauth: false

users:
  - default
  - name: ${VM_USER}
    lock_passwd: true
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_pub_key}

runcmd:${install_cmds}
  - echo "cloud-init-done" > /tmp/cloud-init-done
EOF_USER_DATA

  cat > "$META_DATA_PATH" <<EOF_META_DATA
instance-id: ${DOMAIN_NAME}
local-hostname: ${DOMAIN_NAME}
EOF_META_DATA

  # NOTE: No network-config file — we let passt handle DHCP/DNS on the
  # management NIC automatically. PXE NIC static IP is set via runcmd above.
}

generate_cloud_init_iso() {
  local iso_path="${CLOUD_INIT_DIR}/cloud-init.iso"

  if command_exists genisoimage; then
    genisoimage -output "$iso_path" -volid cidata -joliet -rock \
      "$USER_DATA_PATH" "$META_DATA_PATH" 2>/dev/null
  elif command_exists mkisofs; then
    mkisofs -output "$iso_path" -volid cidata -joliet -rock \
      "$USER_DATA_PATH" "$META_DATA_PATH" 2>/dev/null
  elif command_exists xorriso; then
    xorriso -as genisoimage -output "$iso_path" -volid cidata -joliet -rock \
      "$USER_DATA_PATH" "$META_DATA_PATH" 2>/dev/null
  else
    log_error "no ISO generation tool found (genisoimage, mkisofs, or xorriso required)"
    return 1
  fi

  echo "$iso_path"
}

# --- VM lifecycle ---

DOMAIN_XML_PATH=""
DOMAIN_SERIAL_LOG=""

render_domain_xml() {
  local cloud_init_iso="$1"
  DOMAIN_XML_PATH="${STATE_DIR}/${DOMAIN_NAME}.xml"
  DOMAIN_SERIAL_LOG="${STATE_DIR}/${DOMAIN_NAME}.serial.log"

  cat > "$DOMAIN_XML_PATH" <<EOF
<domain type='kvm'>
  <name>$(printf '%s' "$DOMAIN_NAME" | xml_escape)</name>
  <memory unit='MiB'>$(printf '%s' "$VM_MEMORY_MIB" | xml_escape)</memory>
  <vcpu>$(printf '%s' "$VM_VCPUS" | xml_escape)</vcpu>
  <os>
    <type arch='x86_64'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
  </features>
  <cpu mode='host-passthrough'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='$(printf '%s' "$DOMAIN_DISK_PATH" | xml_escape)'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$(printf '%s' "$cloud_init_iso" | xml_escape)'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='user'>
      <backend type='passt'/>
      <model type='virtio'/>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$SSH_PORT" | xml_escape)' to='22'/>
      </portForward>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$HTTP_PORT" | xml_escape)' to='80'/>
      </portForward>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$BSS_PORT" | xml_escape)' to='27778'/>
      </portForward>
      <portForward proto='tcp' address='127.0.0.1'>
        <range start='$(printf '%s' "$SMD_PORT" | xml_escape)' to='27779'/>
      </portForward>
    </interface>
    <interface type='network'>
      <source network='$(printf '%s' "$PXE_NETWORK_NAME" | xml_escape)'/>
      <model type='virtio'/>
    </interface>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <serial type='pty'>
      <log file='$(printf '%s' "$DOMAIN_SERIAL_LOG" | xml_escape)' append='off'/>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
EOF
}

create_domain() {
  local cloud_init_iso
  cloud_init_iso="$(generate_cloud_init_iso)"

  log_info "creating domain: $DOMAIN_NAME"
  render_domain_xml "$cloud_init_iso"

  sudo -n virsh define "$DOMAIN_XML_PATH" >/dev/null
  sudo -n virsh start "$DOMAIN_NAME" >/dev/null
}

destroy_domain() {
  if ! domain_exists; then
    log_info "domain $DOMAIN_NAME does not exist"
    return 0
  fi

  log_info "destroying domain: $DOMAIN_NAME"
  if domain_is_running; then
    sudo -n virsh destroy "$DOMAIN_NAME" >/dev/null 2>&1 || true
  fi
  sudo -n virsh undefine "$DOMAIN_NAME" --remove-all-storage >/dev/null 2>&1 || true

  # Clean up state
  rm -rf "${CLOUD_INIT_DIR}" "${SHARED_DIR}"
  rm -f "$DOMAIN_DISK_PATH"
  log_info "domain $DOMAIN_NAME destroyed"
}

wait_for_ssh() {
  local elapsed=0

  log_info "waiting for SSH on port $SSH_PORT (timeout: ${SSH_TIMEOUT_SECONDS}s)"
  while [ "$elapsed" -lt "$SSH_TIMEOUT_SECONDS" ]; do
    if ssh_cmd "true" 2>/dev/null; then
      log_info "SSH is ready (${elapsed}s)"
      return 0
    fi
    sleep "$SSH_POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + SSH_POLL_INTERVAL_SECONDS))
  done

  log_error "SSH not ready after ${SSH_TIMEOUT_SECONDS}s"
  return 1
}

wait_for_cloud_init() {
  log_info "waiting for cloud-init completion"
  local attempts=0
  local max_attempts=120

  while [ "$attempts" -lt "$max_attempts" ]; do
    if ssh_cmd "test -f /tmp/cloud-init-done" 2>/dev/null; then
      log_info "cloud-init complete"
      return 0
    fi
    sleep 5
    attempts=$((attempts + 1))
  done

  log_error "cloud-init did not complete in time"
  return 1
}

# --- Package installation and verification ---

install_package() {
  local pkg_name
  pkg_name="$(basename "$PACKAGE_FILE")"

  log_info "copying package to VM: $pkg_name"
  scp_to_vm "$PACKAGE_FILE" "/tmp/$pkg_name"

  # Wait for any background package manager locks to be released (cloud-init).
  log_info "waiting for package manager lock to be released"
  local lock_wait=0
  while [ "$lock_wait" -lt 300 ]; do
    if ssh_cmd "sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo fuser /var/run/yum.pid >/dev/null 2>&1" 2>/dev/null; then
      sleep 5
      lock_wait=$((lock_wait + 5))
    else
      break
    fi
  done

  log_info "installing package on VM"
  if [ "$PKG_TYPE" = "rpm" ]; then
    ssh_cmd "sudo dnf install -y /tmp/$pkg_name"
  else
    ssh_cmd "sudo dpkg -i /tmp/$pkg_name || sudo apt-get install -yf"
  fi
}

create_secrets_file() {
  log_info "creating test secrets file on VM"
  ssh_cmd "sudo tee /etc/openchami/openchami.env > /dev/null" <<'EOF_SECRETS'
POSTGRES_PASSWORD=test-postgres-password
SMD_DB_PASSWORD=test-smd-password
BSS_DB_PASSWORD=test-bss-password
KEA_DB_PASSWORD=test-kea-password
PCS_DB_PASSWORD=test-pcs-password
STORK_DB_PASSWORD=test-stork-password
EOF_SECRETS
  ssh_cmd "sudo chmod 600 /etc/openchami/openchami.env"
}

activate_openchami() {
  log_info "activating OpenCHAMI on VM"
  ssh_cmd "sudo /usr/libexec/openchami/activate"
}

copy_boot_artifacts() {
  log_info "building boot artifacts"
  local artifacts_out
  artifacts_out="$(OPENCHAMI_TEST_NODE_IMAGE="$TEST_NODE_IMAGE" nix build --impure "${NIX_FLAKE_REF}#boot-artifacts-${TEST_NODE_IMAGE}" --no-link --print-out-paths)"

  log_info "copying boot artifacts to VM"
  # Copy the entire artifacts output to the VM
  local tmp_tar
  tmp_tar="$(mktemp)"
  tar -cf "$tmp_tar" -C "$artifacts_out" .
  scp_to_vm "$tmp_tar" "/tmp/boot-artifacts.tar"
  rm -f "$tmp_tar"

  ssh_cmd "sudo mkdir -p /etc/openchami/artifacts && sudo tar -xf /tmp/boot-artifacts.tar -C /etc/openchami/artifacts/"
}

# --- Verification ---

verify_installation() {
  local failures=0

  log_info "==> verifying package installation"

  # Check package is installed
  log_info "checking package installation"
  if [ "$PKG_TYPE" = "rpm" ]; then
    if ssh_cmd "rpm -q openchami-quadlets" 2>/dev/null; then
      log_info "  OK: package installed"
    else
      log_error "  FAIL: package not installed"
      failures=$((failures + 1))
    fi
  else
    if ssh_cmd "dpkg -l openchami-quadlets 2>/dev/null | grep -q '^ii'" 2>/dev/null; then
      log_info "  OK: package installed"
    else
      log_error "  FAIL: package not installed"
      failures=$((failures + 1))
    fi
  fi

  # Check files in expected paths
  log_info "checking file layout"
  local -a expected_paths=(
    "/etc/systemd/system/openchami.target"
    "/etc/openchami/configs.templates"
    "/etc/openchami/openchami.env.template"
    "/usr/libexec/openchami/activate"
    "/usr/libexec/openchami/deactivate"
  )
  for path in "${expected_paths[@]}"; do
    if ssh_cmd "test -e $path" 2>/dev/null; then
      log_info "  OK: $path exists"
    else
      log_error "  FAIL: $path missing"
      failures=$((failures + 1))
    fi
  done

  # Check .container files exist
  log_info "checking quadlet .container files"
  local container_count
  container_count="$(ssh_cmd "ls /etc/containers/systemd/*.container 2>/dev/null | wc -l" 2>/dev/null || echo 0)"
  if [ "$container_count" -gt 0 ]; then
    log_info "  OK: $container_count .container files found"
  else
    log_error "  FAIL: no .container files found"
    failures=$((failures + 1))
  fi

  # Check openchami.target is loaded
  log_info "checking systemd target"
  if ssh_cmd "systemctl list-units --type=target --all 2>/dev/null | grep -q openchami" 2>/dev/null; then
    log_info "  OK: openchami.target is loaded"
  else
    log_warn "  WARN: openchami.target not yet loaded (may need daemon-reload)"
  fi

  # Check activation ran configs were rendered
  log_info "checking rendered configs"
  if ssh_cmd "test -d /etc/openchami/configs && ls /etc/openchami/configs/ 2>/dev/null | grep -q ." 2>/dev/null; then
    log_info "  OK: configs rendered"
  else
    log_error "  FAIL: configs not rendered"
    failures=$((failures + 1))
  fi

  # Check podman containers — postgres uses a public image so it should be running.
  # Other services use localhost/* images that require `make build-images` to load,
  # which is outside the scope of RPM/DEB package testing.
  log_info "checking postgres container (public image, should run without image build)"
  local wait_elapsed=0
  local postgres_ok="false"
  while [ "$wait_elapsed" -lt 120 ]; do
    if ssh_cmd "sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -q postgres" 2>/dev/null; then
      postgres_ok="true"
      break
    fi
    sleep 10
    wait_elapsed=$((wait_elapsed + 10))
  done
  if [ "$postgres_ok" = "true" ]; then
    log_info "  OK: postgres container running"
    ssh_cmd "sudo podman ps --format 'table {{.Names}}\t{{.Status}}'" 2>/dev/null || true
  else
    log_error "  FAIL: postgres container not running after 120s"
    ssh_cmd "sudo systemctl status postgres.service" 2>/dev/null || true
    failures=$((failures + 1))
  fi

  # Report on other services (informational — they need locally-built images)
  log_info "service image status (localhost/* images need 'make build-images' to load):"
  ssh_cmd "sudo systemctl list-units 'smd*' 'bss*' 'kea*' 'pcs*' 'http*' 'tftp*' 'cloud*' --no-pager --no-legend 2>/dev/null" 2>/dev/null || true

  echo ""
  if [ "$failures" -eq 0 ]; then
    log_info "==> all verification checks passed"
  else
    log_error "==> $failures verification check(s) failed"
    return 1
  fi
}

# --- Main ---

ensure_host_prerequisites() {
  require_command virsh "libvirt management"
  require_command qemu-img "disk image management"
  require_command curl "downloading cloud images"
  require_command ssh "SSH to VMs"
  require_command ssh-keygen "SSH key generation"
  require_command nix "building packages"
}

main() {
  case "$ACTION" in
    destroy)
      destroy_domain
      return 0
      ;;
    test)
      ;;
    *)
      log_error "unknown action: $ACTION"
      exit 1
      ;;
  esac

  ensure_host_prerequisites
  ensure_state_dirs
  ensure_ssh_key

  # Step 1: Build packages
  build_packages

  # Step 2: Prepare VM
  if domain_exists; then
    log_info "domain $DOMAIN_NAME already exists; destroying and recreating"
    destroy_domain
  fi

  ensure_base_image
  ensure_domain_disk
  write_cloud_init
  create_domain

  # Step 3: Wait for VM readiness
  wait_for_ssh
  wait_for_cloud_init

  # Step 4: Install and configure
  install_package
  create_secrets_file
  activate_openchami

  # Step 5: Optionally copy boot artifacts
  if [ "$TEST_NODE_IMAGE" != "none" ]; then
    copy_boot_artifacts
  fi

  # Step 6: Verify
  verify_installation

  log_info "package test for $DISTRO completed successfully"
  log_info "SSH: ssh -i $SSH_KEY_PATH -p $SSH_PORT ${VM_USER}@127.0.0.1"
}

main
