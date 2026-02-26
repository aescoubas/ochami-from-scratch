#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/build_microservices.sh"

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

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: $msg"
        echo "  missing substring: $needle"
        echo "  actual: $haystack"
        return 1
    fi
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    local msg="$3"
    if ! rg -q -- "$pattern" "$file"; then
        echo "FAIL: $msg"
        echo "  file: $file"
        echo "  expected pattern: $pattern"
        return 1
    fi
}

PREPARE_CAPTURED=""
BUILD_CAPTURED=""
BUILD_MICROSERVICES_FILE="$PROJECT_ROOT/scripts/build_microservices.sh"
MAKE_BINARIES_CALLS=0
MAKE_FAIL_BINARIES_ATTEMPTS=0
RETRY_SLEEP_CALLS=0

prepare_repo() {
    PREPARE_CAPTURED="$1|$2|$3"
}

make() {
    if [ "${1:-}" = "binaries" ]; then
        MAKE_BINARIES_CALLS=$((MAKE_BINARIES_CALLS + 1))
        if [ "$MAKE_BINARIES_CALLS" -le "$MAKE_FAIL_BINARIES_ATTEMPTS" ]; then
            return 1
        fi
    fi
    return 0
}

docker() {
    BUILD_CAPTURED="$*"
    return 0
}

sleep() {
    RETRY_SLEEP_CALLS=$((RETRY_SLEEP_CALLS + 1))
    return 0
}

test_build_smd_separates_git_ref_and_image_tag() {
    PREPARE_CAPTURED=""
    BUILD_CAPTURED=""
    CONTAINER_TOOL=docker
    SMD_REPO_URI="https://github.com/dev/smd-fork.git"
    build_smd "feature/smd-fast-path" "local-smd"

    assert_eq "$PREPARE_CAPTURED" "smd|feature/smd-fast-path|https://github.com/dev/smd-fork.git" "build_smd should checkout requested git ref from requested repository URI" || return 1
    assert_contains "$BUILD_CAPTURED" "-t localhost/smd:local-smd" "build_smd should use explicit image tag" || return 1
}

test_prepare_repo_relaxes_permissions_for_container_builds() {
    assert_file_contains "$BUILD_MICROSERVICES_FILE" 'chmod -R a\+rX "\$repo_dir"' \
        "prepare_repo should relax repository permissions to avoid unreadable migration files in built images" || return 1
}

test_build_bss_retries_transient_make_binaries_failures() {
    PREPARE_CAPTURED=""
    BUILD_CAPTURED=""
    MAKE_BINARIES_CALLS=0
    MAKE_FAIL_BINARIES_ATTEMPTS=1
    RETRY_SLEEP_CALLS=0
    CONTAINER_TOOL=docker

    local tmp_output
    tmp_output="$(mktemp)"
    if ! BUILD_RETRY_ATTEMPTS=3 BUILD_RETRY_DELAY_SECONDS=0 build_bss "main" "local-bss" "https://github.com/dev/bss-fork.git" >"$tmp_output" 2>&1; then
        echo "FAIL: build_bss should succeed after a transient make binaries failure"
        cat "$tmp_output"
        rm -f "$tmp_output"
        return 1
    fi
    local output
    output="$(cat "$tmp_output")"
    rm -f "$tmp_output"

    assert_eq "$MAKE_BINARIES_CALLS" "2" "build_bss should retry make binaries once after a transient failure" || return 1
    assert_eq "$RETRY_SLEEP_CALLS" "1" "retry helper should sleep between failed attempts" || return 1
    assert_contains "$PREPARE_CAPTURED" "bss|main|https://github.com/dev/bss-fork.git" "build_bss should prepare repository before retries" || return 1
    assert_contains "$BUILD_CAPTURED" "-t localhost/bss:local-bss" "build_bss should still perform docker build after retry" || return 1
    assert_contains "$output" "Attempt 1/3 failed for: make binaries" "retry helper should log attempt failures" || return 1
}

run_test() {
    local test_name="$1"
    if "$test_name"; then
        echo "PASS: $test_name"
    else
        exit 1
    fi
}

run_test test_build_smd_separates_git_ref_and_image_tag
run_test test_prepare_repo_relaxes_permissions_for_container_builds
run_test test_build_bss_retries_transient_make_binaries_failures
