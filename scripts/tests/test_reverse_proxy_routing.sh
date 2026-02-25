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

test_reverse_proxy_has_smd_route() {
    assert_contains "$PROJECT_ROOT/scripts/templates/nginx-default.conf.template" \
        "location /hsm/" "shared nginx template must proxy /hsm"
    assert_contains "$PROJECT_ROOT/scripts/templates/nginx-default.conf.template" \
        "location /api/" "shared nginx template must proxy /api to stork"
    assert_contains "$PROJECT_ROOT/ochami-helm/templates/http-server-nginx-configmap.yaml" \
        "location /hsm/" "helm nginx configmap must proxy /hsm"
    assert_contains "$PROJECT_ROOT/ochami-helm/templates/http-server-nginx-configmap.yaml" \
        "location /api/" "helm nginx configmap must proxy /api to stork"
}

test_docker_compose_routes_smd_calls_through_reverse_proxy() {
    local file="$PROJECT_ROOT/ochami-docker-compose/docker-compose.yml"
    assert_contains "$file" "HSM_URL: \"http://localhost:\\$\\{HTTP_PORT:-80\\}\"" \
        "docker-compose bss should use reverse proxy for HSM"
    assert_contains "$file" "\"http://localhost:\\$\\{HTTP_PORT:-80\\}\"" \
        "docker-compose services should use reverse proxy base URL"
    assert_not_contains "$file" "HSM_URL: \"http://localhost:\\$\\{SMD_PORT:-27779\\}\"" \
        "docker-compose must not use direct SMD URL for HSM"
    assert_not_contains "$file" "SMS_SERVER: \"http://localhost:\\$\\{SMD_PORT:-27779\\}\"" \
        "docker-compose must not use direct SMD URL for PCS"
    assert_not_contains "$file" "SMD_URL: \"http://localhost:\\$\\{SMD_PORT:-27779\\}\"" \
        "docker-compose must not use direct SMD URL for kea sidecar"
    assert_contains "$file" "STORK_AGENT_SERVER_URL: \"http://localhost:\\$\\{HTTP_PORT:-80\\}\"" \
        "docker-compose stork-agent should use reverse proxy"
    assert_not_contains "$file" "STORK_AGENT_SERVER_URL: \"http://localhost:\\$\\{STORK_PORT:-28010\\}\"" \
        "docker-compose stork-agent must not call stork directly"
}

test_docker_compose_macos_routes_smd_calls_through_reverse_proxy() {
    local file="$PROJECT_ROOT/ochami-docker-compose/docker-compose.macos.yml"
    assert_contains "$file" "HSM_URL: \"http://http-server:\\$\\{HTTP_PORT:-80\\}\"" \
        "docker-compose macOS bss should use reverse proxy for HSM"
    assert_contains "$file" "SMS_SERVER: \"http://http-server:\\$\\{HTTP_PORT:-80\\}\"" \
        "docker-compose macOS pcs should use reverse proxy for SMS"
    assert_contains "$file" "SMD_URL: \"http://http-server:\\$\\{HTTP_PORT:-80\\}\"" \
        "docker-compose macOS kea sidecar should use reverse proxy for SMD"
    assert_contains "$file" "STORK_AGENT_SERVER_URL: \"http://http-server:\\$\\{HTTP_PORT:-80\\}\"" \
        "docker-compose macOS stork-agent should use reverse proxy"
    assert_not_contains "$file" "\"http://smd:\\$\\{SMD_PORT:-27779\\}\"" \
        "docker-compose macOS must not use direct SMD URL"
    assert_not_contains "$file" "STORK_AGENT_SERVER_URL: \"http://stork-server:\\$\\{STORK_PORT:-28010\\}\"" \
        "docker-compose macOS stork-agent must not call stork directly"
}

test_quadlets_route_smd_calls_through_reverse_proxy() {
    assert_contains "$PROJECT_ROOT/scripts/deploy/lib/runtime_config.sh" \
        "HSM_URL=http://localhost:\\$\\{HTTP_PORT\\}" \
        "quadlets env should route HSM through reverse proxy"
    assert_contains "$PROJECT_ROOT/scripts/deploy/lib/runtime_config.sh" \
        "SMS_SERVER=http://localhost:\\$\\{HTTP_PORT\\}" \
        "quadlets env should route SMS through reverse proxy"
    assert_contains "$PROJECT_ROOT/scripts/deploy/lib/runtime_config.sh" \
        "STORK_AGENT_SERVER_URL=http://localhost:\\$\\{HTTP_PORT\\}" \
        "quadlets env should route stork agent through reverse proxy"

    assert_contains "$PROJECT_ROOT/ochami-quadlets/containers/cloud-init-server.container" \
        "--smd-url http://localhost:\\$\\{HTTP_PORT\\}" \
        "quadlets cloud-init should route SMD calls through reverse proxy"
    assert_contains "$PROJECT_ROOT/ochami-quadlets/containers/kea-sidecar.container" \
        "Environment=SMD_URL=http://localhost:\\$\\{HTTP_PORT\\}" \
        "quadlets kea-sidecar should route SMD calls through reverse proxy"
    assert_contains "$PROJECT_ROOT/ochami-quadlets/containers/bss-init.container" \
        "http://localhost:\\$\\{HTTP_PORT\\}/hsm/v2/service/ready" \
        "quadlets bss-init should route readiness through reverse proxy"
}

test_helm_routes_smd_calls_through_reverse_proxy() {
    local bss="$PROJECT_ROOT/ochami-helm/templates/bss-pod.yaml"
    local pcs="$PROJECT_ROOT/ochami-helm/templates/pcs-pod.yaml"
    local cloud="$PROJECT_ROOT/ochami-helm/templates/cloud-init-pod.yaml"
    local kea="$PROJECT_ROOT/ochami-helm/templates/kea-pod.yaml"

    assert_contains "$bss" "HSM_URL" "helm bss template should define HSM_URL"
    assert_contains "$bss" "include \"ochami-helm.reverseProxyUrl\" ." \
        "helm bss should route HSM through reverse proxy service"
    assert_not_contains "$bss" "ochami-smd" \
        "helm bss template must not call SMD directly"
    assert_not_contains "$bss" "nc -z" \
        "helm bss init must not depend on nc for readiness checks"
    assert_contains "$bss" "pg_isready -t 1 -h" \
        "helm bss init should use pg_isready for postgres readiness"
    assert_contains "$bss" "/hsm/v2/service/ready" \
        "helm bss init should wait for SMD readiness via reverse proxy"

    assert_contains "$pcs" "SMS_SERVER" "helm pcs template should define SMS_SERVER"
    assert_contains "$pcs" "include \"ochami-helm.reverseProxyUrl\" ." \
        "helm pcs should route SMS through reverse proxy service"
    assert_not_contains "$pcs" "ochami-smd" \
        "helm pcs template must not call SMD directly"

    assert_contains "$cloud" "--smd-url" "helm cloud-init should define smd-url"
    assert_contains "$cloud" "include \"ochami-helm.reverseProxyUrl\" ." \
        "helm cloud-init should route through reverse proxy service"
    assert_not_contains "$cloud" "ochami-smd" \
        "helm cloud-init template must not call SMD directly"

    assert_contains "$kea" "SMD_URL" "helm kea sidecar should define SMD_URL"
    assert_contains "$kea" "include \"ochami-helm.reverseProxyUrl\" ." \
        "helm kea sidecar should route through reverse proxy service"
    assert_not_contains "$kea" "ochami-smd" \
        "helm kea template must not call SMD directly"
    assert_contains "$kea" "STORK_AGENT_SERVER_URL" \
        "helm stork agent should route through reverse proxy service"
    assert_contains "$kea" "include \"ochami-helm.reverseProxyUrl\" ." \
        "helm stork agent should use reverse proxy helper"
    assert_not_contains "$kea" "ochami-stork-server" \
        "helm kea template must not call stork directly"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_reverse_proxy_has_smd_route
run_test test_docker_compose_routes_smd_calls_through_reverse_proxy
run_test test_docker_compose_macos_routes_smd_calls_through_reverse_proxy
run_test test_quadlets_route_smd_calls_through_reverse_proxy
run_test test_helm_routes_smd_calls_through_reverse_proxy
