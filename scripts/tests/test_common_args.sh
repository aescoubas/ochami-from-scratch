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
