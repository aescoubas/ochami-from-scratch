#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

test_helm_templates_use_configurable_termination_grace() {
    local templates=(
        "$PROJECT_ROOT/ochami-helm/templates/smd-pod.yaml"
        "$PROJECT_ROOT/ochami-helm/templates/bss-pod.yaml"
        "$PROJECT_ROOT/ochami-helm/templates/pcs-pod.yaml"
    )

    local template
    for template in "${templates[@]}"; do
        assert_contains "$template" 'terminationGracePeriodSeconds: \{\{ \.Values\.terminationGracePeriodSeconds \}\}' \
            "template should source termination grace period from chart values"
        assert_not_contains "$template" 'terminationGracePeriodSeconds: 0' \
            "template must not hardcode zero termination grace period"
        assert_not_contains "$template" 'TODO: remove this line for production' \
            "template must not keep production TODO comments"
    done
}

test_helm_values_default_to_production_safe_grace() {
    local values_file="$PROJECT_ROOT/ochami-helm/values.yaml"
    assert_contains "$values_file" '^terminationGracePeriodSeconds: 30$' \
        "default helm values should set production-safe grace period"
}

test_helm_values_pxe_profile_overrides_for_fast_shutdown() {
    local values_file="$PROJECT_ROOT/ochami-helm/values-pxe.yaml"
    assert_contains "$values_file" '^terminationGracePeriodSeconds: 0$' \
        "pxe override values should set fast local shutdown grace period"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_helm_templates_use_configurable_termination_grace
run_test test_helm_values_default_to_production_safe_grace
run_test test_helm_values_pxe_profile_overrides_for_fast_shutdown
