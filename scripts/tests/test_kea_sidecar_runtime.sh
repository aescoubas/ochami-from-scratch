#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/ochami-docker-compose/docker-compose.yml"
QUADLET_FILE="$PROJECT_ROOT/ochami-quadlets/containers/kea-sidecar.container"
HELM_POD_TEMPLATE="$PROJECT_ROOT/ochami-helm/templates/kea-pod.yaml"
HELM_VALUES="$PROJECT_ROOT/ochami-helm/values.yaml"
SIDECAR_DOCKERFILE="$PROJECT_ROOT/ochami-helm/kea-sidecar/Dockerfile"
SIDECAR_REQUIREMENTS="$PROJECT_ROOT/ochami-helm/kea-sidecar/requirements.txt"
COMMON_SCRIPT="$PROJECT_ROOT/scripts/common.sh"

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

test_docker_compose_kea_sidecar_uses_prebuilt_image() {
    assert_contains "$COMPOSE_FILE" 'kea-sidecar:' \
        "docker-compose should define kea-sidecar service"
    assert_contains "$COMPOSE_FILE" 'image: localhost/kea-sidecar:latest' \
        "docker-compose kea-sidecar should use local prebuilt image"
    assert_not_contains "$COMPOSE_FILE" 'pip install psycopg2-binary requests' \
        "docker-compose kea-sidecar should not install python deps at runtime"
}

test_quadlets_kea_sidecar_uses_prebuilt_image() {
    assert_contains "$QUADLET_FILE" '^Image=localhost/kea-sidecar:latest' \
        "quadlets kea-sidecar should use local prebuilt image"
    assert_contains "$QUADLET_FILE" '^Exec=python -u /app/smd_sync.py' \
        "quadlets kea-sidecar should execute baked sidecar script"
    assert_not_contains "$QUADLET_FILE" 'pip install psycopg2-binary requests' \
        "quadlets kea-sidecar should not install python deps at runtime"
}

test_helm_kea_sidecar_uses_prebuilt_image() {
    assert_contains "$HELM_VALUES" 'repository: localhost/kea-sidecar' \
        "helm values should point kea sidecar image to local prebuilt image"
    assert_contains "$HELM_POD_TEMPLATE" 'command: \["python", "-u", "/app/smd_sync.py"\]' \
        "helm kea sidecar should execute baked sidecar script"
    assert_not_contains "$HELM_POD_TEMPLATE" 'pip install psycopg2-binary requests' \
        "helm kea sidecar should not install python deps at runtime"
}

test_kea_sidecar_image_context_exists_with_pinned_dependencies() {
    assert_contains "$SIDECAR_DOCKERFILE" '^ARG BASE_IMAGE=' \
        "kea-sidecar Dockerfile should define BASE_IMAGE arg"
    assert_contains "$SIDECAR_DOCKERFILE" 'pip install --no-cache-dir -r /tmp/requirements\.txt' \
        "kea-sidecar Dockerfile should install dependencies at build time"
    assert_contains "$SIDECAR_REQUIREMENTS" '^psycopg2-binary==' \
        "kea-sidecar requirements should pin psycopg2-binary"
    assert_contains "$SIDECAR_REQUIREMENTS" '^requests==' \
        "kea-sidecar requirements should pin requests"
}

test_common_build_flow_builds_kea_sidecar_image() {
    assert_contains "$COMMON_SCRIPT" 'IMAGE_KEA_SIDECAR="localhost/kea-sidecar:latest"' \
        "common build flow should define kea-sidecar image constant"
    assert_contains "$COMMON_SCRIPT" '--build-arg BASE_IMAGE="\$BASE_IMAGE_KEA_SIDECAR"' \
        "common build flow should pass kea-sidecar BASE_IMAGE from centralized catalog"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_docker_compose_kea_sidecar_uses_prebuilt_image
run_test test_quadlets_kea_sidecar_uses_prebuilt_image
run_test test_helm_kea_sidecar_uses_prebuilt_image
run_test test_kea_sidecar_image_context_exists_with_pinned_dependencies
run_test test_common_build_flow_builds_kea_sidecar_image
