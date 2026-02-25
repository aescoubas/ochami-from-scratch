#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UBUNTU_PREREQ_SCRIPT="$PROJECT_ROOT/scripts/install_prerequisites.sh"
FEDORA_PREREQ_SCRIPT="$PROJECT_ROOT/scripts/install_prerequisites_fedora.sh"
COMMON_SCRIPT="$PROJECT_ROOT/scripts/common.sh"
MINIKUBE_DEPLOY_SCRIPT="$PROJECT_ROOT/scripts/deploy/minikube.sh"
DOCKER_DEPLOY_SCRIPT="$PROJECT_ROOT/scripts/deploy/docker-compose.sh"
QUADLETS_DEPLOY_SCRIPT="$PROJECT_ROOT/scripts/deploy/quadlets.sh"
VM_RUNNER_SCRIPT="$PROJECT_ROOT/libvirt/scripts/run_tests.sh"
MINIKUBE_TEARDOWN_SCRIPT="$PROJECT_ROOT/scripts/teardown/minikube.sh"
DOCKER_TEARDOWN_SCRIPT="$PROJECT_ROOT/scripts/teardown/docker-compose.sh"
QUADLETS_TEARDOWN_SCRIPT="$PROJECT_ROOT/scripts/teardown/quadlets.sh"

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

test_prereq_scripts_make_sysctl_mutation_opt_in() {
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'SET_FS_PROTECTED_REGULAR=false' \
        "Ubuntu prerequisites should default fs.protected_regular mutation to opt-in"
    assert_contains "$UBUNTU_PREREQ_SCRIPT" '--set-fs-protected-regular\) SET_FS_PROTECTED_REGULAR=true' \
        "Ubuntu prerequisites should parse --set-fs-protected-regular"
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'if \[ "\$SET_FS_PROTECTED_REGULAR" = true \]; then' \
        "Ubuntu prerequisites should gate sysctl mutation behind explicit opt-in"
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'Not modifying fs\.protected_regular by default' \
        "Ubuntu prerequisites should document non-mutating default behavior"

    assert_contains "$FEDORA_PREREQ_SCRIPT" 'SET_FS_PROTECTED_REGULAR=false' \
        "Fedora prerequisites should default fs.protected_regular mutation to opt-in"
    assert_contains "$FEDORA_PREREQ_SCRIPT" '--set-fs-protected-regular\) SET_FS_PROTECTED_REGULAR=true' \
        "Fedora prerequisites should parse --set-fs-protected-regular"
    assert_contains "$FEDORA_PREREQ_SCRIPT" 'if \[ "\$SET_FS_PROTECTED_REGULAR" = true \]; then' \
        "Fedora prerequisites should gate sysctl mutation behind explicit opt-in"
    assert_contains "$FEDORA_PREREQ_SCRIPT" 'Not modifying fs\.protected_regular by default' \
        "Fedora prerequisites should document non-mutating default behavior"
}

test_common_deploy_args_expose_sysctl_opt_in_flag() {
    assert_contains "$COMMON_SCRIPT" 'DEFAULT_SET_FS_PROTECTED_REGULAR=false' \
        "common deploy defaults should include fs.protected_regular opt-in flag"
    assert_contains "$COMMON_SCRIPT" 'SET_FS_PROTECTED_REGULAR="\$DEFAULT_SET_FS_PROTECTED_REGULAR"' \
        "parse_common_deploy_args should initialize SET_FS_PROTECTED_REGULAR"
    assert_contains "$COMMON_SCRIPT" '--set-fs-protected-regular\) SET_FS_PROTECTED_REGULAR=true' \
        "parse_common_deploy_args should parse --set-fs-protected-regular"
    assert_contains "$COMMON_SCRIPT" 'Opt in to setting host fs\.protected_regular=0 during prerequisite install' \
        "common help should document --set-fs-protected-regular"
}

test_deploy_and_vm_runner_wire_opt_in_flag_explicitly() {
    assert_contains "$MINIKUBE_DEPLOY_SCRIPT" 'PREREQ_ARGS=\(\)' \
        "minikube deploy should build prerequisite arg list"
    assert_contains "$MINIKUBE_DEPLOY_SCRIPT" 'PREREQ_ARGS\+=\(--set-fs-protected-regular\)' \
        "minikube deploy should pass --set-fs-protected-regular when enabled"
    assert_contains "$MINIKUBE_DEPLOY_SCRIPT" 'install_prerequisites\.sh" "\$\{PREREQ_ARGS\[@\]\}"' \
        "minikube deploy should call prerequisites with explicit args"

    assert_contains "$DOCKER_DEPLOY_SCRIPT" 'PREREQ_ARGS\+=\(--set-fs-protected-regular\)' \
        "docker-compose deploy should pass --set-fs-protected-regular when enabled"
    assert_contains "$QUADLETS_DEPLOY_SCRIPT" 'PREREQ_ARGS\+=\(--set-fs-protected-regular\)' \
        "quadlets deploy should pass --set-fs-protected-regular when enabled"

    assert_contains "$VM_RUNNER_SCRIPT" 'SET_FS_PROTECTED_REGULAR_FOR_TESTS="\$\{SET_FS_PROTECTED_REGULAR_FOR_TESTS:-true\}"' \
        "VM runner should set explicit fs.protected_regular policy for integration tests"
    assert_contains "$VM_RUNNER_SCRIPT" 'prereq_args\+=\(--set-fs-protected-regular\)' \
        "VM runner should pass --set-fs-protected-regular explicitly when enabled"
}

test_sysctl_restore_is_managed_not_blind() {
    assert_contains "$COMMON_SCRIPT" '^restore_fs_protected_regular_if_managed\(\)' \
        "common helpers should include managed fs.protected_regular restore"

    assert_contains "$MINIKUBE_TEARDOWN_SCRIPT" 'restore_fs_protected_regular_if_managed' \
        "minikube teardown should use managed fs.protected_regular restore"
    assert_contains "$DOCKER_TEARDOWN_SCRIPT" 'restore_fs_protected_regular_if_managed' \
        "docker-compose teardown should use managed fs.protected_regular restore"
    assert_contains "$QUADLETS_TEARDOWN_SCRIPT" 'restore_fs_protected_regular_if_managed' \
        "quadlets teardown should use managed fs.protected_regular restore"
    assert_not_contains "$MINIKUBE_TEARDOWN_SCRIPT" 'sysctl -w fs\.protected_regular=1' \
        "minikube teardown should not blindly reset fs.protected_regular=1"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_prereq_scripts_make_sysctl_mutation_opt_in
run_test test_common_deploy_args_expose_sysctl_opt_in_flag
run_test test_deploy_and_vm_runner_wire_opt_in_flag_explicitly
run_test test_sysctl_restore_is_managed_not_blind
