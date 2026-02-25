#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPELINE_LIB="$PROJECT_ROOT/scripts/deploy/lib/pipeline.sh"
MINIKUBE_DEPLOY="$PROJECT_ROOT/scripts/deploy/minikube.sh"
QUADLETS_DEPLOY="$PROJECT_ROOT/scripts/deploy/quadlets.sh"
DOCKER_COMPOSE_DEPLOY="$PROJECT_ROOT/scripts/deploy/docker-compose.sh"

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

test_pipeline_library_exists() {
    if [ ! -f "$PIPELINE_LIB" ]; then
        echo "FAIL: shared pipeline library should exist"
        echo "  missing file: $PIPELINE_LIB"
        exit 1
    fi

    assert_contains "$PIPELINE_LIB" '^common_deploy_bootstrap\(\)' \
        "pipeline library should define shared bootstrap helper"
    assert_contains "$PIPELINE_LIB" '^common_install_prerequisites\(\)' \
        "pipeline library should define shared prerequisites helper"
    assert_contains "$PIPELINE_LIB" '^common_run_post_deploy_flow\(\)' \
        "pipeline library should define shared post-deploy flow helper"
}

test_deploy_methods_use_shared_pipeline() {
    assert_contains "$MINIKUBE_DEPLOY" 'lib/pipeline\.sh' \
        "minikube deploy should source shared pipeline library"
    assert_contains "$QUADLETS_DEPLOY" 'lib/pipeline\.sh' \
        "quadlets deploy should source shared pipeline library"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'lib/pipeline\.sh' \
        "docker-compose deploy should source shared pipeline library"

    assert_contains "$MINIKUBE_DEPLOY" 'common_deploy_bootstrap "OpenCHAMI Minikube Deployment"' \
        "minikube deploy should use shared bootstrap helper"
    assert_contains "$QUADLETS_DEPLOY" 'common_deploy_bootstrap "OpenCHAMI Quadlets Deployment"' \
        "quadlets deploy should use shared bootstrap helper"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'common_deploy_bootstrap "OpenCHAMI Docker Compose Deployment"' \
        "docker-compose deploy should use shared bootstrap helper"

    assert_contains "$MINIKUBE_DEPLOY" 'common_install_prerequisites' \
        "minikube deploy should use shared prerequisites helper"
    assert_contains "$QUADLETS_DEPLOY" 'common_install_prerequisites' \
        "quadlets deploy should use shared prerequisites helper"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'common_install_prerequisites' \
        "docker-compose deploy should use shared prerequisites helper"

    assert_contains "$MINIKUBE_DEPLOY" 'common_run_post_deploy_flow' \
        "minikube deploy should use shared post-deploy flow helper"
    assert_contains "$QUADLETS_DEPLOY" 'common_run_post_deploy_flow' \
        "quadlets deploy should use shared post-deploy flow helper"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'common_run_post_deploy_flow' \
        "docker-compose deploy should use shared post-deploy flow helper"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_pipeline_library_exists
run_test test_deploy_methods_use_shared_pipeline
