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

assert_matches() {
    local value="$1"
    local pattern="$2"
    local description="$3"

    if [[ ! "$value" =~ $pattern ]]; then
        echo "FAIL: $description"
        echo "  value: $value"
        echo "  expected regex: $pattern"
        exit 1
    fi
}

test_base_image_catalog_exists_and_is_digest_pinned() {
    local file="$PROJECT_ROOT/scripts/image-bases.env"
    [ -f "$file" ] || {
        echo "FAIL: centralized base image catalog must exist"
        exit 1
    }

    # shellcheck disable=SC1090
    source "$file"

    assert_matches "${BASE_IMAGE_HTTP_SERVER:-}" '@sha256:[0-9a-f]{64}$' \
        "http-server base image should be digest pinned"
    assert_matches "${BASE_IMAGE_REDFISH_EMULATOR:-}" '@sha256:[0-9a-f]{64}$' \
        "redfish-emulator base image should be digest pinned"
    assert_matches "${BASE_IMAGE_TFTP:-}" '@sha256:[0-9a-f]{64}$' \
        "tftp base image should be digest pinned"
    assert_matches "${BASE_IMAGE_STORK_AGENT:-}" '@sha256:[0-9a-f]{64}$' \
        "stork-agent base image should be digest pinned"
    assert_matches "${BASE_IMAGE_KEA_SIDECAR:-}" '@sha256:[0-9a-f]{64}$' \
        "kea-sidecar base image should be digest pinned"
    assert_matches "${BASE_IMAGE_SLES_BUILDER:-}" '@sha256:[0-9a-f]{64}$' \
        "sles builder base image should be digest pinned"
}

test_local_dockerfiles_use_build_arg_base_image() {
    local http_server="$PROJECT_ROOT/ochami-helm/http-server/Dockerfile"
    local redfish="$PROJECT_ROOT/ochami-helm/redfish-emulator/Dockerfile"
    local tftp="$PROJECT_ROOT/ochami-helm/tftp/Dockerfile"
    local stork_agent="$PROJECT_ROOT/ochami-helm/stork-agent/Dockerfile"
    local kea_sidecar="$PROJECT_ROOT/ochami-helm/kea-sidecar/Dockerfile"

    assert_contains "$http_server" '^ARG BASE_IMAGE=' \
        "http-server Dockerfile must define BASE_IMAGE arg"
    assert_contains "$http_server" '^FROM \$\{BASE_IMAGE\}' \
        "http-server Dockerfile must use BASE_IMAGE arg"

    assert_contains "$redfish" '^ARG BASE_IMAGE=' \
        "redfish-emulator Dockerfile must define BASE_IMAGE arg"
    assert_contains "$redfish" '^FROM \$\{BASE_IMAGE\}' \
        "redfish-emulator Dockerfile must use BASE_IMAGE arg"

    assert_contains "$tftp" '^ARG BASE_IMAGE=' \
        "tftp Dockerfile must define BASE_IMAGE arg"
    assert_contains "$tftp" '^FROM \$\{BASE_IMAGE\}' \
        "tftp Dockerfile must use BASE_IMAGE arg"

    assert_contains "$stork_agent" '^ARG BASE_IMAGE=' \
        "stork-agent Dockerfile must define BASE_IMAGE arg"
    assert_contains "$stork_agent" '^FROM \$\{BASE_IMAGE\}' \
        "stork-agent Dockerfile must use BASE_IMAGE arg"

    assert_contains "$kea_sidecar" '^ARG BASE_IMAGE=' \
        "kea-sidecar Dockerfile must define BASE_IMAGE arg"
    assert_contains "$kea_sidecar" '^FROM \$\{BASE_IMAGE\}' \
        "kea-sidecar Dockerfile must use BASE_IMAGE arg"
}

test_build_scripts_source_catalog_and_pass_build_args() {
    local common="$PROJECT_ROOT/scripts/common.sh"
    local build_images="$PROJECT_ROOT/scripts/build_and_load_images.sh"

    assert_contains "$common" 'source "\$PROJECT_ROOT/scripts/image-bases.env"' \
        "common.sh should source centralized base image catalog"
    assert_contains "$build_images" 'source "\$SCRIPT_DIR/(common\.sh|image-bases\.env)"' \
        "build_and_load_images.sh should source common.sh or image-bases.env for centralized base images"

    assert_contains "$common" '--build-arg BASE_IMAGE="\$BASE_IMAGE_TFTP"' \
        "tftp build should pass BASE_IMAGE from catalog"
    assert_contains "$common" '--build-arg BASE_IMAGE="\$BASE_IMAGE_STORK_AGENT"' \
        "stork-agent build should pass BASE_IMAGE from catalog"
    assert_contains "$common" '--build-arg BASE_IMAGE="\$BASE_IMAGE_KEA_SIDECAR"' \
        "kea-sidecar build should pass BASE_IMAGE from catalog"
    assert_contains "$common" 'build_local_image_for_tool\(\)' \
        "common build path should define helper that guarantees local image availability"
    assert_contains "$common" 'docker buildx build --load' \
        "common build path should retry with buildx --load when docker build does not load image"
    assert_contains "$common" 'docker save "\$IMAGE_TFTP" \| minikube image load -' \
        "tftp minikube load should stream tarball to avoid daemon context mismatches"
    assert_contains "$common" 'docker save "\$IMAGE_STORK_AGENT" \| minikube image load -' \
        "stork-agent minikube load should stream tarball to avoid daemon context mismatches"
    assert_contains "$common" 'docker save "\$IMAGE_KEA_SIDECAR" \| minikube image load -' \
        "kea-sidecar minikube load should stream tarball to avoid daemon context mismatches"

    assert_contains "$build_images" '--build-arg BASE_IMAGE="\$BASE_IMAGE_HTTP_SERVER"' \
        "http-server build should pass BASE_IMAGE from catalog"
    assert_contains "$build_images" '--build-arg BASE_IMAGE="\$BASE_IMAGE_REDFISH_EMULATOR"' \
        "redfish-emulator build should pass BASE_IMAGE from catalog"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_base_image_catalog_exists_and_is_digest_pinned
run_test test_local_dockerfiles_use_build_arg_base_image
run_test test_build_scripts_source_catalog_and_pass_build_args
