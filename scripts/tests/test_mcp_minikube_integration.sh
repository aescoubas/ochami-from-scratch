#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MINIKUBE_DEPLOY="$PROJECT_ROOT/scripts/deploy/minikube.sh"
QUADLETS_DEPLOY="$PROJECT_ROOT/scripts/deploy/quadlets.sh"
DOCKER_COMPOSE_DEPLOY="$PROJECT_ROOT/scripts/deploy/docker-compose.sh"
MCP_SERVER="$PROJECT_ROOT/scripts/mcp/openchami_mcp_server.py"
MCP_API="$PROJECT_ROOT/scripts/mcp/openchami_api.py"
MCP_RUNNER="$PROJECT_ROOT/scripts/mcp/run_openchami_mcp.sh"
README_FILE="$PROJECT_ROOT/README.md"

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

assert_file_exists() {
    local file="$1"
    local description="$2"
    if [ ! -f "$file" ]; then
        echo "FAIL: $description"
        echo "  missing file: $file"
        exit 1
    fi
}

test_mcp_server_files_exist() {
    assert_file_exists "$MCP_SERVER" "python MCP server should exist"
    assert_file_exists "$MCP_API" "python OpenCHAMI API helper should exist"
    assert_file_exists "$MCP_RUNNER" "MCP runner helper should exist"
}

test_minikube_deploy_mentions_mcp_workflow() {
    assert_contains "$MINIKUBE_DEPLOY" '\.openchami-mcp\.env' \
        "minikube deploy should generate MCP env file"
    assert_contains "$MINIKUBE_DEPLOY" 'OPENCHAMI_BASE_URL=' \
        "minikube deploy should write reverse proxy base URL for MCP"
    assert_contains "$MINIKUBE_DEPLOY" 'run_openchami_mcp\.sh' \
        "minikube deploy should print MCP startup command"
}

test_non_minikube_deploys_do_not_wire_mcp() {
    assert_not_contains "$QUADLETS_DEPLOY" 'run_openchami_mcp\.sh' \
        "quadlets deploy should not include MCP startup guidance yet"
    assert_not_contains "$DOCKER_COMPOSE_DEPLOY" 'run_openchami_mcp\.sh' \
        "docker-compose deploy should not include MCP startup guidance yet"
    assert_not_contains "$QUADLETS_DEPLOY" '\.openchami-mcp\.env' \
        "quadlets deploy should not generate MCP env file"
    assert_not_contains "$DOCKER_COMPOSE_DEPLOY" '\.openchami-mcp\.env' \
        "docker-compose deploy should not generate MCP env file"
}

test_readme_mcp_setup_is_current() {
    assert_contains "$README_FILE" 'startup_timeout_sec' \
        "README should document MCP startup timeout tuning for codex clients"
    assert_contains "$README_FILE" '\[mcp_servers\.openchami\]' \
        "README should include codex config.toml MCP server example"
    assert_contains "$README_FILE" 'openchami_health' \
        "README should list read-only MCP tool names"
    assert_contains "$README_FILE" 'pcs_transition' \
        "README should list write-capable PCS MCP tool name"
    assert_contains "$README_FILE" 'bss_get_bootscript' \
        "README should list BSS read MCP tool name"
    assert_contains "$README_FILE" 'bss_patch_bootparameters' \
        "README should list BSS write MCP tool name"
    assert_contains "$README_FILE" '--enable-writes' \
        "README should document run_openchami_mcp.sh write-ack flag"
    assert_contains "$README_FILE" 'OPENCHAMI_BASE_URL=http://<host-ip>:30080' \
        "README should document minikube-generated MCP base URL source"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_mcp_server_files_exist
run_test test_minikube_deploy_mentions_mcp_workflow
run_test test_non_minikube_deploys_do_not_wire_mcp
run_test test_readme_mcp_setup_is_current
