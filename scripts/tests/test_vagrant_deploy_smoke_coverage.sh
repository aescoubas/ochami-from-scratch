#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE_TEST="$PROJECT_ROOT/vagrant/scripts/smoke_test.sh"
RUN_TESTS="$PROJECT_ROOT/vagrant/scripts/run_tests.sh"
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

test_smoke_checks_boot_artifacts() {
    assert_contains "$SMOKE_TEST" '/artifacts/vmlinuz-lts' \
        "vagrant smoke test should validate kernel artifact reachability"
    assert_contains "$SMOKE_TEST" '/artifacts/initramfs-lts' \
        "vagrant smoke test should validate initramfs artifact reachability"
    assert_contains "$SMOKE_TEST" '/artifacts/rootfs\.squashfs' \
        "vagrant smoke test should validate rootfs artifact reachability"
}

test_smoke_checks_bss_smd_integration() {
    assert_contains "$SMOKE_TEST" 'register_hardware_node\.sh' \
        "vagrant smoke test should exercise hardware node registration"
    assert_contains "$SMOKE_TEST" '/hsm/v2/State/Components' \
        "vagrant smoke test should verify SMD component registration"
    assert_contains "$SMOKE_TEST" '/boot/v1/bootscript\?mac=' \
        "vagrant smoke test should verify BSS boot script lookup by MAC"
}

test_run_tests_invokes_smoke_suite() {
    assert_contains "$RUN_TESTS" 'run_smoke_tests "\$method"' \
        "vagrant run_tests should execute smoke tests after each deploy"
}

test_make_vm_targets_force_rsync_before_execution() {
    assert_contains "$MAKEFILE" 'vagrant rsync ubuntu' \
        "test-vm-ubuntu target should force rsync to refresh guest checkout"
    assert_contains "$MAKEFILE" 'vagrant rsync fedora' \
        "test-vm-fedora target should force rsync to refresh guest checkout"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_smoke_checks_boot_artifacts
run_test test_smoke_checks_bss_smd_integration
run_test test_run_tests_invokes_smoke_suite
run_test test_make_vm_targets_force_rsync_before_execution
