#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMON_SCRIPT="$PROJECT_ROOT/scripts/common.sh"
MINIKUBE_TEARDOWN_SCRIPT="$PROJECT_ROOT/scripts/teardown/minikube.sh"
DOCKER_TEARDOWN_SCRIPT="$PROJECT_ROOT/scripts/teardown/docker-compose.sh"
QUADLETS_TEARDOWN_SCRIPT="$PROJECT_ROOT/scripts/teardown/quadlets.sh"
VM_RUNNER_SCRIPT="$PROJECT_ROOT/libvirt/scripts/run_tests.sh"
README_FILE="$PROJECT_ROOT/README.md"

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

test_common_teardown_args_support_network_overrides() {
    assert_contains "$COMMON_SCRIPT" 'PXE_INTERFACE="\$DEFAULT_PXE_INTERFACE"' \
        "teardown args should default PXE interface"
    assert_contains "$COMMON_SCRIPT" 'PXE_IP="\$DEFAULT_PXE_IP"' \
        "teardown args should default PXE IP"
    assert_contains "$COMMON_SCRIPT" 'PXE_CIDR="\$DEFAULT_PXE_CIDR"' \
        "teardown args should default PXE CIDR"
    assert_contains "$COMMON_SCRIPT" '--interface\) PXE_INTERFACE="\$2"; shift' \
        "teardown args should parse --interface"
    assert_contains "$COMMON_SCRIPT" '--ip\) PXE_IP="\$2"; shift' \
        "teardown args should parse --ip"
    assert_contains "$COMMON_SCRIPT" '--cidr\) PXE_CIDR="\$2"; shift' \
        "teardown args should parse --cidr"
    assert_contains "$COMMON_SCRIPT" '--interface NAME      PXE interface to clean up' \
        "teardown help should document --interface"
    assert_contains "$COMMON_SCRIPT" '--ip IP               PXE IP to remove from interface' \
        "teardown help should document --ip"
    assert_contains "$COMMON_SCRIPT" '--cidr N              PXE CIDR prefix for IP cleanup' \
        "teardown help should document --cidr"
}

test_host_network_cleanup_uses_dynamic_cidr() {
    assert_contains "$COMMON_SCRIPT" 'local host_cidr="\$\{3:-24\}"' \
        "cleanup_host_networking should accept a host CIDR argument"
    assert_contains "$COMMON_SCRIPT" 'ip addr del "\$host_ip/\$host_cidr" dev "\$host_iface"' \
        "cleanup_host_networking should remove IP using the provided CIDR"
}

test_teardown_methods_pass_network_cleanup_args() {
    assert_contains "$MINIKUBE_TEARDOWN_SCRIPT" 'cleanup_host_networking "\$PXE_INTERFACE" "\$PXE_IP" "\$PXE_CIDR"' \
        "minikube teardown should pass interface/IP/CIDR to host networking cleanup"
    assert_contains "$DOCKER_TEARDOWN_SCRIPT" 'cleanup_host_networking "\$PXE_INTERFACE" "\$PXE_IP" "\$PXE_CIDR"' \
        "docker-compose teardown should pass interface/IP/CIDR to host networking cleanup"
    assert_contains "$QUADLETS_TEARDOWN_SCRIPT" 'cleanup_host_networking "\$PXE_INTERFACE" "\$PXE_IP" "\$PXE_CIDR"' \
        "quadlets teardown should pass interface/IP/CIDR to host networking cleanup"
}

test_vm_runner_passes_teardown_network_args() {
    assert_contains "$VM_RUNNER_SCRIPT" 'bash "\$PROJECT_ROOT/teardown\.sh" --method "\$method" --interface "\$PXE_TEST_INTERFACE" --ip "\$PXE_TEST_IP" --cidr "\$PXE_TEST_CIDR" -y' \
        "vm runner teardown should pass interface/IP/CIDR cleanup args to teardown"
}

test_readme_documents_teardown_network_overrides() {
    assert_contains "$README_FILE" '\| `--interface NAME` \| PXE interface to clean up \(default: virbr-pxe\) \|' \
        "README teardown options should document --interface"
    assert_contains "$README_FILE" '\| `--ip IP` \| PXE IP to remove during host cleanup \(default: 192\.168\.100\.2\) \|' \
        "README teardown options should document --ip"
    assert_contains "$README_FILE" '\| `--cidr N` \| PXE CIDR prefix to use for host cleanup \(default: 24\) \|' \
        "README teardown options should document --cidr"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_common_teardown_args_support_network_overrides
run_test test_host_network_cleanup_uses_dynamic_cidr
run_test test_teardown_methods_pass_network_cleanup_args
run_test test_vm_runner_passes_teardown_network_args
run_test test_readme_documents_teardown_network_overrides
