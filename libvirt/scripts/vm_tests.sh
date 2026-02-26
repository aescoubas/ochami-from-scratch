#!/bin/bash
set -euo pipefail

# vm_tests.sh — libvirt-native VM test runner for OpenCHAMI
# Replaces Vagrant lifecycle with direct virsh/virt-install orchestration.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
STATE_ROOT="${LIBVIRT_STATE_ROOT:-/tmp/ochami-libvirt-tests}"
IMAGE_DIR="$STATE_ROOT/images"
CLOUD_INIT_DIR="$STATE_ROOT/cloud-init"
SSH_KEY_DIR="$STATE_ROOT/ssh"

VM_MEMORY_MIB="${VM_MEMORY_MIB:-6144}"
VM_VCPUS="${VM_VCPUS:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-60G}"
SSH_TIMEOUT_SECONDS="${SSH_TIMEOUT_SECONDS:-600}"
SSH_POLL_INTERVAL_SECONDS="${SSH_POLL_INTERVAL_SECONDS:-5}"

UBUNTU_IMAGE_URL="${LIBVIRT_UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
FEDORA_IMAGE_URL="${LIBVIRT_FEDORA_IMAGE_URL:-https://download.fedoraproject.org/pub/fedora/linux/releases/41/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-41-1.4.qcow2}"

DISTRO=""
ACTION="run"
RECREATE="false"
SKIP_SYNC="false"
SKIP_PROVISION="false"

SSH_KEY_PATH=""
SSH_PUB_KEY_PATH=""

DOMAIN_NAME=""
VM_USER=""
OS_VARIANT=""
BASE_IMAGE_URL=""
BASE_IMAGE_PATH=""
DOMAIN_DISK_PATH=""
USER_DATA_PATH=""
META_DATA_PATH=""
REMOTE_PROJECT_DIR=""

log() {
    echo "[libvirt-vm] $*"
}

usage() {
    cat <<USAGE
Usage:
  $0 --distro ubuntu|fedora [--recreate] [--skip-sync] [--skip-provision]
  $0 --distro ubuntu|fedora --destroy
  $0 --destroy-all

Options:
  --distro DISTRO   Guest distro to run (ubuntu|fedora)
  --destroy         Destroy only the selected distro VM
  --destroy-all     Destroy both ubuntu and fedora test VMs
  --recreate        Destroy and recreate the selected distro VM before running tests
  --skip-sync       Skip rsync workspace synchronization
  --skip-provision  Skip guest provisioning script
USAGE
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    fi
}

ensure_host_prerequisites() {
    require_command virsh
    require_command virt-install
    require_command qemu-img
    require_command curl
    require_command ssh
    require_command ssh-keygen
    require_command rsync
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --distro)
                DISTRO="$2"
                shift 2
                ;;
            --destroy)
                ACTION="destroy"
                shift
                ;;
            --destroy-all)
                ACTION="destroy-all"
                shift
                ;;
            --recreate)
                RECREATE="true"
                shift
                ;;
            --skip-sync)
                SKIP_SYNC="true"
                shift
                ;;
            --skip-provision)
                SKIP_PROVISION="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown argument: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    if [ "$ACTION" = "destroy-all" ]; then
        return 0
    fi

    if [ -z "$DISTRO" ]; then
        echo "ERROR: --distro is required unless using --destroy-all" >&2
        usage
        exit 1
    fi
}

resolve_distro_config() {
    local distro="$1"

    case "$distro" in
        ubuntu)
            DOMAIN_NAME="ochami-test-ubuntu"
            VM_USER="ubuntu"
            OS_VARIANT="generic"
            BASE_IMAGE_URL="$UBUNTU_IMAGE_URL"
            ;;
        fedora)
            DOMAIN_NAME="ochami-test-fedora"
            VM_USER="fedora"
            OS_VARIANT="generic"
            BASE_IMAGE_URL="$FEDORA_IMAGE_URL"
            ;;
        *)
            echo "ERROR: unsupported distro '$distro'" >&2
            exit 1
            ;;
    esac

    BASE_IMAGE_PATH="$IMAGE_DIR/${distro}-base.qcow2"
    DOMAIN_DISK_PATH="$IMAGE_DIR/${DOMAIN_NAME}.qcow2"
    USER_DATA_PATH="$CLOUD_INIT_DIR/${DOMAIN_NAME}-user-data.yaml"
    META_DATA_PATH="$CLOUD_INIT_DIR/${DOMAIN_NAME}-meta-data.yaml"
    REMOTE_PROJECT_DIR="/home/$VM_USER/ochami-from-scratch"
}

ensure_state_dirs() {
    mkdir -p "$IMAGE_DIR" "$CLOUD_INIT_DIR" "$SSH_KEY_DIR"
}

ensure_ssh_key() {
    SSH_KEY_PATH="$SSH_KEY_DIR/id_ed25519"
    SSH_PUB_KEY_PATH="$SSH_KEY_PATH.pub"

    if [ ! -f "$SSH_KEY_PATH" ]; then
        log "Generating dedicated SSH key for libvirt test guests"
        ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY_PATH" >/dev/null
    fi
}

network_exists() {
    virsh net-info "$LIBVIRT_NETWORK" >/dev/null 2>&1
}

network_is_active() {
    virsh net-info "$LIBVIRT_NETWORK" 2>/dev/null | grep -Eq 'Active:[[:space:]]+yes'
}

wait_for_network_active() {
    local attempts="${1:-5}"
    local delay_seconds="${2:-1}"
    local attempt

    for attempt in $(seq 1 "$attempts"); do
        if network_is_active; then
            return 0
        fi
        sleep "$delay_seconds"
    done

    return 1
}

print_network_diagnostics() {
    echo "libvirt network diagnostics for '$LIBVIRT_NETWORK':" >&2
    virsh net-info "$LIBVIRT_NETWORK" >&2 || true
    virsh net-list --all >&2 || true
}

start_network_if_needed() {
    local net_start_error=""

    if network_is_active; then
        return 0
    fi

    log "Starting libvirt network '$LIBVIRT_NETWORK'"
    if net_start_error="$(virsh net-start "$LIBVIRT_NETWORK" 2>&1 >/dev/null)"; then
        return 0
    fi

    if echo "$net_start_error" | grep -qi "already active"; then
        log "libvirt network '$LIBVIRT_NETWORK' is already active; continuing"
        return 0
    fi

    # Race-safe path: libvirt can report "already active" if state changed
    # between the active check and net-start call.
    if wait_for_network_active 5 1; then
        log "libvirt network '$LIBVIRT_NETWORK' became active while starting; continuing"
        return 0
    fi

    echo "ERROR: failed to start libvirt network '$LIBVIRT_NETWORK'" >&2
    if [ -n "${net_start_error}" ]; then
        echo "net-start error: ${net_start_error}" >&2
    fi
    print_network_diagnostics
    return 1
}

ensure_libvirt_network() {
    if ! network_exists; then
        echo "ERROR: libvirt network '$LIBVIRT_NETWORK' does not exist" >&2
        exit 1
    fi

    if ! start_network_if_needed; then
        exit 1
    fi

    virsh net-autostart "$LIBVIRT_NETWORK" >/dev/null || true
}

write_cloud_init_files() {
    if [ -z "${SSH_PUB_KEY_PATH:-}" ] || [ ! -f "$SSH_PUB_KEY_PATH" ]; then
        echo "ERROR: SSH public key file not found: ${SSH_PUB_KEY_PATH:-<unset>}" >&2
        return 1
    fi

    local ssh_pub_key
    ssh_pub_key="$(cat "$SSH_PUB_KEY_PATH")"
    if [ -z "$ssh_pub_key" ]; then
        echo "ERROR: SSH public key file is empty: $SSH_PUB_KEY_PATH" >&2
        return 1
    fi

    cat > "$USER_DATA_PATH" <<EOF_USER_DATA
#cloud-config
package_update: false
package_upgrade: false
ssh_pwauth: false
users:
  - default
  - name: ${VM_USER}
    lock_passwd: true
    shell: /bin/bash
    ssh_authorized_keys:
      - ${ssh_pub_key}
EOF_USER_DATA

    cat > "$META_DATA_PATH" <<EOF_META_DATA
instance-id: ${DOMAIN_NAME}
local-hostname: ${DOMAIN_NAME}
EOF_META_DATA
}

ensure_base_image() {
    if [ -f "$BASE_IMAGE_PATH" ]; then
        return 0
    fi

    log "Downloading base image for $DISTRO"
    curl -fL --retry 3 --retry-delay 2 -o "$BASE_IMAGE_PATH" "$BASE_IMAGE_URL"
}

ensure_domain_disk() {
    if [ -f "$DOMAIN_DISK_PATH" ]; then
        return 0
    fi

    log "Creating overlay disk: $DOMAIN_DISK_PATH"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE_PATH" "$DOMAIN_DISK_PATH" "$VM_DISK_SIZE" >/dev/null
}

domain_exists() {
    virsh dominfo "$DOMAIN_NAME" >/dev/null 2>&1
}

create_domain() {
    log "Creating domain: $DOMAIN_NAME"
    virt-install \
        --name "$DOMAIN_NAME" \
        --memory "$VM_MEMORY_MIB" \
        --vcpus "$VM_VCPUS" \
        --cpu host-passthrough \
        --import \
        --disk "path=$DOMAIN_DISK_PATH,format=qcow2,bus=virtio" \
        --network "network=$LIBVIRT_NETWORK,model=virtio" \
        --os-variant "$OS_VARIANT" \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --cloud-init "user-data=$USER_DATA_PATH,meta-data=$META_DATA_PATH,clouduser-ssh-key=$SSH_PUB_KEY_PATH,disable=on" \
        >/dev/null
}

ensure_domain_running() {
    if ! domain_exists; then
        create_domain
        return 0
    fi

    local state
    state="$(virsh domstate "$DOMAIN_NAME" 2>/dev/null | tr -d '\r' | xargs)"
    if [ "$state" != "running" ]; then
        log "Starting existing domain: $DOMAIN_NAME"
        virsh start "$DOMAIN_NAME" >/dev/null
    fi
}

get_domain_mac() {
    local mac
    mac="$(virsh domiflist "$DOMAIN_NAME" | awk -v net="$LIBVIRT_NETWORK" '$2 == "network" && $3 == net {print $5; exit}')"
    if [ -z "$mac" ]; then
        mac="$(virsh domiflist "$DOMAIN_NAME" | awk '$2 == "network" {print $5; exit}')"
    fi
    echo "$mac"
}

get_domain_ip() {
    local mac ip
    mac="$(get_domain_mac)"
    if [ -z "$mac" ]; then
        return 1
    fi

    ip="$(virsh net-dhcp-leases "$LIBVIRT_NETWORK" --mac "$mac" 2>/dev/null \
        | awk '/ipv4/ {for (i = 1; i <= NF; i++) {if ($i ~ /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/) {split($i, a, "/"); print a[1]; exit}}}')"

    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    ip="$(virsh domifaddr "$DOMAIN_NAME" --source lease 2>/dev/null \
        | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')"
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    ip="$(virsh domifaddr "$DOMAIN_NAME" --source agent 2>/dev/null \
        | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}')"
    if [ -n "$ip" ]; then
        echo "$ip"
        return 0
    fi

    return 1
}

wait_for_ssh() {
    local elapsed=0
    local ip=""

    while [ "$elapsed" -lt "$SSH_TIMEOUT_SECONDS" ]; do
        ip="$(get_domain_ip || true)"
        if [ -n "$ip" ] && ssh -i "$SSH_KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes \
            -o ConnectTimeout=5 \
            "$VM_USER@$ip" true >/dev/null 2>&1; then
            echo "$ip"
            return 0
        fi

        sleep "$SSH_POLL_INTERVAL_SECONDS"
        elapsed=$((elapsed + SSH_POLL_INTERVAL_SECONDS))
    done

    echo "ERROR: timed out waiting for SSH on domain '$DOMAIN_NAME'" >&2
    return 1
}

sync_workspace() {
    local vm_ip="$1"

    log "Syncing workspace to guest: $VM_USER@$vm_ip"
    ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        "$VM_USER@$vm_ip" "mkdir -p '$REMOTE_PROJECT_DIR'"

    RSYNC_RSH="ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"
    RSYNC_RSH="$RSYNC_RSH" rsync -az --delete \
        --exclude ".git/" \
        --exclude "ochami-smd/" \
        --exclude "ochami-bss/" \
        --exclude "ochami-coresmd/" \
        --exclude "ochami-cloud-init/" \
        --exclude "initramfs-lts" \
        --exclude "rootfs.squashfs" \
        --exclude "vmlinuz-lts" \
        "$PROJECT_ROOT/" "$VM_USER@$vm_ip:$REMOTE_PROJECT_DIR/"
}

run_guest_provision() {
    local vm_ip="$1"

    log "Provisioning guest dependencies"
    ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        "$VM_USER@$vm_ip" 'bash -s' < "$SCRIPT_DIR/provision.sh"
}

run_guest_tests() {
    local vm_ip="$1"

    log "Running integration tests in guest"
    ssh -i "$SSH_KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        "$VM_USER@$vm_ip" "cd '$REMOTE_PROJECT_DIR' && sudo /home/$VM_USER/ochami-from-scratch/libvirt/scripts/run_tests.sh"
}

destroy_domain() {
    log "Destroying domain: $DOMAIN_NAME"

    if domain_exists; then
        virsh destroy "$DOMAIN_NAME" >/dev/null 2>&1 || true
        virsh undefine "$DOMAIN_NAME" --nvram >/dev/null 2>&1 || virsh undefine "$DOMAIN_NAME" >/dev/null 2>&1 || true
    fi

    rm -f "$DOMAIN_DISK_PATH" "$USER_DATA_PATH" "$META_DATA_PATH"
}

destroy_all_domains() {
    for distro in ubuntu fedora; do
        resolve_distro_config "$distro"
        destroy_domain
    done
}

main() {
    parse_args "$@"
    ensure_host_prerequisites
    ensure_state_dirs
    ensure_ssh_key

    if [ "$ACTION" = "destroy-all" ]; then
        destroy_all_domains
        return 0
    fi

    resolve_distro_config "$DISTRO"

    if [ "$ACTION" = "destroy" ]; then
        destroy_domain
        return 0
    fi

    ensure_libvirt_network

    if [ "$RECREATE" = "true" ]; then
        destroy_domain
    fi

    write_cloud_init_files
    ensure_base_image
    ensure_domain_disk
    ensure_domain_running

    local vm_ip
    vm_ip="$(wait_for_ssh)"

    if [ "$SKIP_SYNC" != "true" ]; then
        sync_workspace "$vm_ip"
    fi

    if [ "$SKIP_PROVISION" != "true" ]; then
        run_guest_provision "$vm_ip"
    fi

    run_guest_tests "$vm_ip"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
