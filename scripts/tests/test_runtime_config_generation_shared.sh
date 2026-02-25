#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUNTIME_LIB="$PROJECT_ROOT/scripts/deploy/lib/runtime_config.sh"
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

test_runtime_config_library_exists() {
    if [ ! -f "$RUNTIME_LIB" ]; then
        echo "FAIL: shared runtime config library should exist"
        echo "  missing file: $RUNTIME_LIB"
        exit 1
    fi

    assert_contains "$RUNTIME_LIB" '^build_postgres_multiple_databases\(\)' \
        "runtime config library should define postgres db helper"
    assert_contains "$RUNTIME_LIB" '^export_runtime_template_vars\(\)' \
        "runtime config library should define shared env export helper"
    assert_contains "$RUNTIME_LIB" '^render_templates_in_dir\(\)' \
        "runtime config library should define shared template directory renderer"
    assert_contains "$RUNTIME_LIB" '^generate_quadlets_env_file\(\)' \
        "runtime config library should define quadlets env generator"
    assert_contains "$RUNTIME_LIB" '^generate_docker_compose_env_file\(\)' \
        "runtime config library should define docker compose env generator"
}

test_quadlets_and_compose_use_shared_runtime_helpers() {
    assert_contains "$QUADLETS_DEPLOY" 'lib/runtime_config\.sh' \
        "quadlets deploy should source shared runtime config library"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'lib/runtime_config\.sh' \
        "docker-compose deploy should source shared runtime config library"

    assert_contains "$QUADLETS_DEPLOY" 'generate_quadlets_env_file ' \
        "quadlets deploy should use shared env file generator"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'generate_docker_compose_env_file ' \
        "docker-compose deploy should use shared env file generator"

    assert_contains "$QUADLETS_DEPLOY" 'export_runtime_template_vars' \
        "quadlets deploy should use shared template env export helper"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'export_runtime_template_vars' \
        "docker-compose deploy should use shared template env export helper"

    assert_contains "$QUADLETS_DEPLOY" 'render_templates_in_dir' \
        "quadlets deploy should use shared template renderer"
    assert_contains "$DOCKER_COMPOSE_DEPLOY" 'render_template_file' \
        "docker-compose deploy should use shared template renderer"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_runtime_config_library_exists
run_test test_quadlets_and_compose_use_shared_runtime_helpers
