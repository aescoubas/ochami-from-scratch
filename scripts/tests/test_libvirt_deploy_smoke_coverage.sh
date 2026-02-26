#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE_TEST="$PROJECT_ROOT/libvirt/scripts/smoke_test.sh"
RUN_TESTS="$PROJECT_ROOT/libvirt/scripts/run_tests.sh"
VM_TESTS="$PROJECT_ROOT/libvirt/scripts/vm_tests.sh"
MAKEFILE="$PROJECT_ROOT/Makefile"

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

assert_not_contains() {
    local file="$1"
    local pattern="$2"
    local description="$3"

    if rg -q -- "$pattern" "$file"; then
        echo "FAIL: $description"
        echo "  file: $file"
        echo "  unexpected pattern: $pattern"
        exit 1
    fi
}

test_smoke_checks_boot_artifacts() {
    assert_contains "$SMOKE_TEST" '/artifacts/opensuse/vmlinuz-lts' \
        "libvirt smoke test should validate default opensuse kernel artifact reachability"
    assert_contains "$SMOKE_TEST" '/artifacts/opensuse/initramfs-lts' \
        "libvirt smoke test should validate default opensuse initramfs artifact reachability"
    assert_contains "$SMOKE_TEST" '/artifacts/opensuse/rootfs\.squashfs' \
        "libvirt smoke test should validate default opensuse rootfs artifact reachability"
    assert_contains "$SMOKE_TEST" '/artifacts/ubuntu/rootfs\.squashfs' \
        "libvirt smoke test should also validate ubuntu variant rootfs artifact reachability"
}

test_smoke_checks_bss_smd_integration() {
    assert_contains "$SMOKE_TEST" 'register_hardware_node\.sh' \
        "libvirt smoke test should exercise hardware node registration"
    assert_contains "$SMOKE_TEST" '/hsm/v2/State/Components' \
        "libvirt smoke test should verify SMD component registration"
    assert_contains "$SMOKE_TEST" '/boot/v1/bootscript\?mac=' \
        "libvirt smoke test should verify BSS boot script lookup by MAC"
}

test_run_tests_invokes_smoke_suite() {
    assert_contains "$RUN_TESTS" 'run_smoke_tests "\$method"' \
        "libvirt run_tests should execute smoke tests after each deploy"
}

test_libvirt_vm_runner_syncs_workspace_before_execution() {
    assert_contains "$VM_TESTS" 'rsync -az --delete' \
        "libvirt vm runner should sync workspace via rsync"
    assert_contains "$VM_TESTS" '--exclude ".git/"' \
        "libvirt vm runner should exclude .git when syncing workspace"
}

test_make_vm_targets_use_libvirt_runner() {
    assert_contains "$MAKEFILE" 'bash libvirt/scripts/vm_tests\.sh --distro ubuntu' \
        "test-vm-ubuntu should invoke the libvirt vm runner"
    assert_contains "$MAKEFILE" 'bash libvirt/scripts/vm_tests\.sh --distro fedora' \
        "test-vm-fedora should invoke the libvirt vm runner"
    assert_contains "$MAKEFILE" 'bash libvirt/scripts/vm_tests\.sh --destroy-all' \
        "test-vm-destroy should invoke libvirt runner cleanup"
    assert_not_contains "$MAKEFILE" 'vagrant' \
        "Makefile should not depend on vagrant commands for VM tests"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_smoke_checks_boot_artifacts
run_test test_smoke_checks_bss_smd_integration
run_test test_run_tests_invokes_smoke_suite
run_test test_libvirt_vm_runner_syncs_workspace_before_execution
run_test test_make_vm_targets_use_libvirt_runner
