#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/common.sh"

assert_eq() {
    local actual="$1"
    local expected="$2"
    local msg="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $msg"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        exit 1
    fi
}

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

assert_file_missing() {
    local file="$1"
    local description="$2"
    if [ -e "$file" ]; then
        echo "FAIL: $description"
        echo "  unexpected file present: $file"
        exit 1
    fi
}

test_dhcp_conflict_policy_args() {
    parse_common_deploy_args
    assert_eq "${DHCP_CONFLICT_POLICY}" "fail" "default DHCP conflict policy should be fail"

    parse_common_deploy_args --auto-kill
    assert_eq "${DHCP_CONFLICT_POLICY}" "auto-kill" "--auto-kill should set DHCP conflict policy to auto-kill"

    parse_common_deploy_args --auto-kill --fail-on-conflict
    assert_eq "${DHCP_CONFLICT_POLICY}" "fail" "--fail-on-conflict should override prior --auto-kill"
}

test_dhcp_conflict_check_is_non_interactive() {
    assert_not_contains "$PROJECT_ROOT/scripts/common.sh" 'read -r -p' \
        "DHCP conflict handling should not prompt interactively"
}

test_secret_generation_and_no_changeme_defaults() {
    assert_not_contains "$PROJECT_ROOT/scripts/common.sh" 'CHANGEME' \
        "common.sh should not contain CHANGEME defaults"
    assert_not_contains "$PROJECT_ROOT/scripts/deploy/minikube.sh" 'CHANGEME' \
        "minikube deploy should not hardcode CHANGEME"
    assert_not_contains "$PROJECT_ROOT/ochami-helm/values.yaml" 'CHANGEME' \
        "helm values should not hardcode CHANGEME defaults"
    assert_not_contains "$PROJECT_ROOT/ochami-docker-compose/docker-compose.yml" 'CHANGEME' \
        "docker-compose should not hardcode CHANGEME defaults"

    assert_contains "$PROJECT_ROOT/scripts/common.sh" '^ensure_generated_secrets\(\)' \
        "common.sh should define ensure_generated_secrets helper"
    assert_contains "$PROJECT_ROOT/scripts/deploy/minikube.sh" 'ensure_generated_secrets' \
        "minikube deploy should generate secrets before deploy"
    assert_contains "$PROJECT_ROOT/scripts/deploy/quadlets.sh" 'ensure_generated_secrets' \
        "quadlets deploy should generate secrets before deploy"
    assert_contains "$PROJECT_ROOT/scripts/deploy/docker-compose.sh" 'ensure_generated_secrets' \
        "docker-compose deploy should generate secrets before deploy"

    assert_contains "$PROJECT_ROOT/scripts/common.sh" 'local old_umask' \
        "ensure_generated_secrets should preserve the caller umask"
    assert_contains "$PROJECT_ROOT/scripts/common.sh" 'umask "\$old_umask"' \
        "ensure_generated_secrets should restore umask after writing secrets"
}

test_hardware_registration_is_deduplicated() {
    assert_contains "$PROJECT_ROOT/scripts/common.sh" '^register_hardware_node_with_endpoints\(\)' \
        "common.sh should define shared hardware registration function"
    assert_contains "$PROJECT_ROOT/scripts/register_hardware_node.sh" 'register_hardware_node_with_endpoints' \
        "register_hardware_node.sh should reuse shared registration function"
    assert_not_contains "$PROJECT_ROOT/scripts/register_hardware_node.sh" '/hsm/v2/State/Components' \
        "register_hardware_node.sh should not duplicate direct SMD registration calls"
    assert_not_contains "$PROJECT_ROOT/scripts/register_hardware_node.sh" '/boot/v1/bootparameters' \
        "register_hardware_node.sh should not duplicate direct BSS registration calls"
}

test_nginx_template_generation_is_shared() {
    assert_contains "$PROJECT_ROOT/scripts/deploy/docker-compose.sh" 'scripts/templates/nginx-default\.conf\.template' \
        "docker-compose deploy should use shared nginx template"
    assert_contains "$PROJECT_ROOT/scripts/deploy/quadlets.sh" 'scripts/templates/nginx-default\.conf\.template' \
        "quadlets deploy should use shared nginx template"

    assert_contains "$PROJECT_ROOT/scripts/templates/nginx-default.conf.template" 'location /hsm/' \
        "shared nginx template should include SMD route"
    assert_contains "$PROJECT_ROOT/scripts/templates/nginx-default.conf.template" 'location /power-control/' \
        "shared nginx template should include PCS route"

    assert_file_missing "$PROJECT_ROOT/ochami-docker-compose/configs/nginx-default.conf.template" \
        "docker-compose-specific nginx template should be removed"
    assert_file_missing "$PROJECT_ROOT/ochami-quadlets/configs/nginx-default.conf.template" \
        "quadlets-specific nginx template should be removed"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_dhcp_conflict_policy_args
run_test test_dhcp_conflict_check_is_non_interactive
run_test test_secret_generation_and_no_changeme_defaults
run_test test_hardware_registration_is_deduplicated
run_test test_nginx_template_generation_is_shared
