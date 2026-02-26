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
        return 1
    fi
}

test_default_microservice_refs() {
    parse_common_deploy_args
    assert_eq "${SMD_REF}" "main" "default SMD ref should be main"
    assert_eq "${BSS_REF}" "main" "default BSS ref should be main"
    assert_eq "${PCS_REF}" "main" "default PCS ref should be main"
    assert_eq "${SMD_REPO_URI}" "https://github.com/aescoubas/ochami-smd.git" "default SMD repo URI"
    assert_eq "${BSS_REPO_URI}" "https://github.com/aescoubas/ochami-bss.git" "default BSS repo URI"
    assert_eq "${PCS_REPO_URI}" "https://github.com/OpenCHAMI/power-control.git" "default PCS repo URI"
    assert_eq "${DISCOVERY_METHOD}" "static" "default discovery method should be static"
    assert_eq "${MAGELLAN_SUBNETS}" "" "default magellan subnets should be empty"
    assert_eq "${MAGELLAN_HOSTS}" "" "default magellan hosts should be empty"
    assert_eq "${MAGELLAN_INSECURE}" "false" "default magellan insecure should be false"
}

test_custom_microservice_refs() {
    parse_common_deploy_args \
        --smd-ref "feature/smd-fast-path" \
        --bss-ref "fix/bss-db-timeout" \
        --pcs-ref "bugfix/pcs-retry" \
        --smd-repo-uri "https://github.com/dev/smd-fork.git" \
        --bss-repo-uri "https://github.com/dev/bss-fork.git" \
        --pcs-repo-uri "https://github.com/dev/power-control-fork.git"
    assert_eq "${SMD_REF}" "feature/smd-fast-path" "custom SMD ref parsing"
    assert_eq "${BSS_REF}" "fix/bss-db-timeout" "custom BSS ref parsing"
    assert_eq "${PCS_REF}" "bugfix/pcs-retry" "custom PCS ref parsing"
    assert_eq "${SMD_REPO_URI}" "https://github.com/dev/smd-fork.git" "custom SMD repo URI parsing"
    assert_eq "${BSS_REPO_URI}" "https://github.com/dev/bss-fork.git" "custom BSS repo URI parsing"
    assert_eq "${PCS_REPO_URI}" "https://github.com/dev/power-control-fork.git" "custom PCS repo URI parsing"
}

test_get_microservice_ref() {
    parse_common_deploy_args --smd-ref "feature/smd-a" --bss-ref "feature/bss-b" --pcs-ref "feature/pcs-c"
    assert_eq "$(get_microservice_ref smd)" "feature/smd-a" "SMD ref resolution"
    assert_eq "$(get_microservice_ref bss)" "feature/bss-b" "BSS ref resolution"
    assert_eq "$(get_microservice_ref pcs)" "feature/pcs-c" "PCS ref resolution"
}

test_get_microservice_repo_uri() {
    parse_common_deploy_args \
        --smd-repo-uri "https://github.com/dev/smd.git" \
        --bss-repo-uri "https://github.com/dev/bss.git" \
        --pcs-repo-uri "https://github.com/dev/pcs.git"
    assert_eq "$(get_microservice_repo_uri smd)" "https://github.com/dev/smd.git" "SMD repo URI resolution"
    assert_eq "$(get_microservice_repo_uri bss)" "https://github.com/dev/bss.git" "BSS repo URI resolution"
    assert_eq "$(get_microservice_repo_uri pcs)" "https://github.com/dev/pcs.git" "PCS repo URI resolution"
}

test_magellan_discovery_args() {
    parse_common_deploy_args \
        --discovery-method "magellan" \
        --magellan-subnets "172.16.0.0/24,10.20.0.0/16" \
        --magellan-hosts "https://10.0.0.10,10.0.0.11" \
        --magellan-subnet-mask "255.255.255.0" \
        --magellan-bmc-user "admin" \
        --magellan-bmc-pass "secret" \
        --magellan-bmc-id-map "@/tmp/bmc-map.yaml" \
        --magellan-cache "/tmp/magellan-assets.db" \
        --magellan-insecure
    assert_eq "${DISCOVERY_METHOD}" "magellan" "discovery method parsing"
    assert_eq "${MAGELLAN_SUBNETS}" "172.16.0.0/24,10.20.0.0/16" "magellan subnets parsing"
    assert_eq "${MAGELLAN_HOSTS}" "https://10.0.0.10,10.0.0.11" "magellan hosts parsing"
    assert_eq "${MAGELLAN_SUBNET_MASK}" "255.255.255.0" "magellan subnet mask parsing"
    assert_eq "${MAGELLAN_BMC_USER}" "admin" "magellan user parsing"
    assert_eq "${MAGELLAN_BMC_PASS}" "secret" "magellan password parsing"
    assert_eq "${MAGELLAN_BMC_ID_MAP}" "@/tmp/bmc-map.yaml" "magellan bmc id map parsing"
    assert_eq "${MAGELLAN_CACHE}" "/tmp/magellan-assets.db" "magellan cache parsing"
    assert_eq "${MAGELLAN_INSECURE}" "true" "magellan insecure parsing"
}

test_relax_permissions_helper_exists() {
    if ! declare -f relax_permissions >/dev/null 2>&1; then
        echo "FAIL: relax_permissions helper should be defined in common.sh"
        return 1
    fi
}

test_scripts_use_relax_permissions_and_avoid_chown() {
    local deploy_script="$PROJECT_ROOT/scripts/deploy/minikube.sh"
    local build_script="$PROJECT_ROOT/scripts/build_and_load_images.sh"
    local common_script="$PROJECT_ROOT/scripts/common.sh"

    if rg -q '\bchown\b' "$deploy_script" "$build_script"; then
        echo "FAIL: deploy/build scripts should not call chown"
        return 1
    fi

    if ! rg -q 'relax_permissions "\$HOME/\.minikube" "\$HOME/\.kube"' "$deploy_script"; then
        echo "FAIL: minikube deploy should use relax_permissions for kube dirs"
        return 1
    fi

    if ! rg -q 'relax_permissions \./boot_tmp' "$build_script"; then
        echo "FAIL: build script should use relax_permissions for boot_tmp"
        return 1
    fi

    if ! rg -q 'relax_permissions "\$output_squashfs"' "$build_script"; then
        echo "FAIL: build script should use relax_permissions for variant rootfs artifacts"
        return 1
    fi

    if ! rg -q 'relax_permissions\(\)' "$common_script"; then
        echo "FAIL: relax_permissions helper should be implemented in common.sh"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    if "$test_name"; then
        echo "PASS: $test_name"
    else
        exit 1
    fi
}

run_test test_default_microservice_refs
run_test test_custom_microservice_refs
run_test test_get_microservice_ref
run_test test_get_microservice_repo_uri
run_test test_magellan_discovery_args
run_test test_relax_permissions_helper_exists
run_test test_scripts_use_relax_permissions_and_avoid_chown
