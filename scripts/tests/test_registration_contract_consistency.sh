#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SETUP_MINIKUBE_NET="$PROJECT_ROOT/scripts/setup_minikube_net.sh"
REGISTER_LOCAL_VM="$PROJECT_ROOT/scripts/register_local_vm.sh"
MINIKUBE_DEPLOY="$PROJECT_ROOT/scripts/deploy/minikube.sh"
DOCKER_COMPOSE_DEPLOY="$PROJECT_ROOT/scripts/deploy/docker-compose.sh"
CREATE_VM_SCRIPT="$PROJECT_ROOT/scripts/create_vm.sh"
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

test_setup_minikube_net_uses_explicit_network_name() {
    assert_contains "$SETUP_MINIKUBE_NET" '^NET_NAME=\$\{5:-"pxe-net"\}' \
        "setup_minikube_net should define a default network name and allow override"
    assert_contains "$SETUP_MINIKUBE_NET" '--source "\$NET_NAME"' \
        "setup_minikube_net should use NET_NAME for virsh interface attachment"
    assert_contains "$SETUP_MINIKUBE_NET" 'on the \$NET_NAME network\.' \
        "setup_minikube_net should report the selected network name"
}

test_register_local_vm_uses_shared_ports_and_dynamic_artifacts_url() {
    assert_contains "$REGISTER_LOCAL_VM" 'source "\$SCRIPT_DIR/common\.sh"' \
        "register_local_vm should source common.sh for shared constants"
    assert_contains "$REGISTER_LOCAL_VM" 'http://\$\{SMD_IP\}:\$\{SMD_PORT\}/hsm/v2/State/Components' \
        "register_local_vm should use shared SMD port constant"
    assert_contains "$REGISTER_LOCAL_VM" 'http://\$\{BSS_IP\}:\$\{BSS_PORT\}/boot/v1/bootparameters' \
        "register_local_vm should use shared BSS port constant"
    assert_contains "$REGISTER_LOCAL_VM" 'ARTIFACTS_URL="\$\{ARTIFACTS_URL:-http://\$\{HOST_IP\}:\$\{HTTP_PORT\}/artifacts\}"' \
        "register_local_vm should derive artifact URL from HOST_IP and HTTP_PORT defaults"
    assert_not_contains "$REGISTER_LOCAL_VM" 'http://\$\{SMD_IP\}:27779' \
        "register_local_vm must not hardcode SMD port 27779"
    assert_not_contains "$REGISTER_LOCAL_VM" 'http://\$\{BSS_IP\}:27778' \
        "register_local_vm must not hardcode BSS port 27778"
    assert_not_contains "$REGISTER_LOCAL_VM" '192\.168\.100\.2:30080/artifacts' \
        "register_local_vm must not hardcode artifact URL"
}

test_registration_contract_is_consistent() {
    local required_usage='register_hardware_node\.sh <MAC_ADDRESS> <IP_ADDRESS> <COMPONENT_ID> <NID> <BMC_IP> <BMC_USER> <BMC_PASS>'
    local legacy_usage='register_hardware_node\.sh <MAC_ADDRESS> <IP_ADDRESS> \[COMPONENT_ID\] \[NID\]'

    assert_contains "$README_FILE" "$required_usage" \
        "README should document full hardware registration contract"
    assert_contains "$MINIKUBE_DEPLOY" "$required_usage" \
        "minikube deploy output should document full hardware registration contract"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" "$required_usage" \
        "docker-compose deploy output should document full hardware registration contract"
    assert_contains "$CREATE_VM_SCRIPT" "$required_usage" \
        "create_vm macOS guidance should document full hardware registration contract"
    assert_contains "$REGISTER_LOCAL_VM" "$required_usage" \
        "register_local_vm macOS guidance should document full hardware registration contract"

    assert_not_contains "$README_FILE" "$legacy_usage" \
        "README should not document the old optional hardware registration contract"
    assert_not_contains "$MINIKUBE_DEPLOY" "$legacy_usage" \
        "minikube deploy output should not show old optional hardware registration contract"
    assert_not_contains "$DOCKER_COMPOSE_DEPLOY" "$legacy_usage" \
        "docker-compose deploy output should not show old optional hardware registration contract"
    assert_not_contains "$CREATE_VM_SCRIPT" 'register_hardware_node\.sh <MAC_ADDRESS> <IP_ADDRESS> \[COMPONENT_ID\]' \
        "create_vm should not show old optional registration contract"
    assert_not_contains "$REGISTER_LOCAL_VM" "$legacy_usage" \
        "register_local_vm should not show old optional hardware registration contract"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_setup_minikube_net_uses_explicit_network_name
run_test test_register_local_vm_uses_shared_ports_and_dynamic_artifacts_url
run_test test_registration_contract_is_consistent
