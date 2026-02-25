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

prepare_repo() {
    PREPARE_CAPTURED="$1|$2|$3"
}

make() {
    return 0
}

docker() {
    BUILD_CAPTURED="$*"
    return 0
}

test_build_smd_separates_git_ref_and_image_tag() {
    PREPARE_CAPTURED=""
    BUILD_CAPTURED=""
    CONTAINER_TOOL=docker
    SMD_REPO_URI="https://github.com/dev/smd-fork.git"
    build_smd "feature/smd-fast-path" "local-smd"

    assert_eq "$PREPARE_CAPTURED" "smd|feature/smd-fast-path|https://github.com/dev/smd-fork.git" "build_smd should checkout requested git ref from requested repository URI"
    assert_contains "$BUILD_CAPTURED" "-t localhost/smd:local-smd" "build_smd should use explicit image tag"
}

test_prepare_repo_relaxes_permissions_for_container_builds() {
    assert_file_contains "$BUILD_MICROSERVICES_FILE" 'chmod -R a\+rX "\$repo_dir"' \
        "prepare_repo should relax repository permissions to avoid unreadable migration files in built images"
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
