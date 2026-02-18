#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$PROJECT_ROOT/ochami-helm/templates/redfish-emulator-statefulset.yaml"
VALUES="$PROJECT_ROOT/ochami-helm/values.yaml"
MINIKUBE_DEPLOY="$PROJECT_ROOT/scripts/deploy/minikube.sh"

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

test_redfish_mount_is_configurable_in_values_and_template() {
    assert_contains "$VALUES" '^  libvirtSocket:' \
        "values.yaml should define emulator libvirtSocket config"
    assert_contains "$VALUES" '^    enabled: true' \
        "values.yaml should enable emulator libvirt socket by default"
    assert_contains "$TEMPLATE" '\{\{- if \.Values\.emulator\.libvirtSocket\.enabled \}\}' \
        "redfish emulator template should gate socket mount on values flag"
    assert_contains "$TEMPLATE" '\{\{ \.Values\.emulator\.libvirtSocket\.mountPath \| quote \}\}' \
        "redfish emulator template should use configurable mount path"
    assert_contains "$TEMPLATE" '\{\{ \.Values\.emulator\.libvirtSocket\.hostPath \| quote \}\}' \
        "redfish emulator template should use configurable host path"
}

test_macos_minikube_disables_redfish_socket_mount() {
    assert_contains "$MINIKUBE_DEPLOY" 'if \$IS_MACOS; then' \
        "minikube deploy should branch for macOS"
    assert_contains "$MINIKUBE_DEPLOY" 'libvirtSocket:' \
        "minikube deploy should set emulator libvirt socket options"
    assert_contains "$MINIKUBE_DEPLOY" 'enabled: false' \
        "minikube deploy should disable emulator libvirt mount on macOS"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_redfish_mount_is_configurable_in_values_and_template
run_test test_macos_minikube_disables_redfish_socket_mount
