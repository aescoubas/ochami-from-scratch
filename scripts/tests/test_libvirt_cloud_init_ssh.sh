#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VM_TESTS_SCRIPT="$PROJECT_ROOT/libvirt/scripts/vm_tests.sh"

assert_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"
    if ! rg -q -- "$pattern" "$file"; then
        echo "FAIL: $description"
        echo "  file: $file"
        echo "  expected pattern: $pattern"
        exit 1
    fi
}

test_write_cloud_init_includes_vm_user_and_ssh_key() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local user_data="$tmpdir/user-data.yaml"
    local meta_data="$tmpdir/meta-data.yaml"
    local key_path="$tmpdir/id_ed25519.pub"
    local fake_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeOpenChamiKeyForTests test@local'
    printf '%s\n' "$fake_key" > "$key_path"

    (
        source "$VM_TESTS_SCRIPT"
        DOMAIN_NAME="ochami-test-ubuntu"
        VM_USER="ubuntu"
        USER_DATA_PATH="$user_data"
        META_DATA_PATH="$meta_data"
        SSH_PUB_KEY_PATH="$key_path"
        write_cloud_init_files
    )

    assert_contains "$user_data" '^#cloud-config$' \
        "cloud-init should generate a cloud-config file"
    assert_contains "$user_data" '^users:$' \
        "cloud-init should define users"
    assert_contains "$user_data" '^  - name: ubuntu$' \
        "cloud-init should target VM_USER for SSH key installation"
    assert_contains "$user_data" '^    ssh_authorized_keys:$' \
        "cloud-init should configure ssh_authorized_keys"
    assert_contains "$user_data" "$fake_key" \
        "cloud-init should embed the configured SSH public key"
}

test_write_cloud_init_requires_existing_ssh_pub_key_file() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    local user_data="$tmpdir/user-data.yaml"
    local meta_data="$tmpdir/meta-data.yaml"
    local missing_key="$tmpdir/missing.pub"
    local stderr_file="$tmpdir/stderr.log"

    set +e
    (
        source "$VM_TESTS_SCRIPT"
        DOMAIN_NAME="ochami-test-ubuntu"
        VM_USER="ubuntu"
        USER_DATA_PATH="$user_data"
        META_DATA_PATH="$meta_data"
        SSH_PUB_KEY_PATH="$missing_key"
        write_cloud_init_files
    ) > /dev/null 2>"$stderr_file"
    local status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        echo "FAIL: write_cloud_init_files should fail when SSH public key file is missing"
        exit 1
    fi

    assert_contains "$stderr_file" "SSH public key file not found" \
        "cloud-init helper should emit a clear error for missing SSH key"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_write_cloud_init_includes_vm_user_and_ssh_key
run_test test_write_cloud_init_requires_existing_ssh_pub_key_file
