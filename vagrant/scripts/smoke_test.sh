#!/bin/bash
# smoke_test.sh — Health-check library for OpenCHAMI integration tests
# Source this file, then call: run_smoke_tests <method>

# Default timeout for service readiness (seconds)
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-120}"
SMOKE_INTERVAL="${SMOKE_INTERVAL:-3}"

# Service endpoints (relative to localhost)
SMD_READY_URL="http://localhost:27779/hsm/v2/service/ready"
BSS_READY_URL="http://localhost:27778/boot/v1/bootparameters"
CLOUD_INIT_URL="http://localhost:27777/cloud-init/version"
PCS_READY_URL="http://localhost:28007/liveness"
STORK_READY_URL="http://localhost:28010/api/version"

_smoke_wait_for_url() {
    local url="$1"
    local label="$2"
    local timeout="${3:-$SMOKE_TIMEOUT}"
    local interval="${4:-$SMOKE_INTERVAL}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -s -f -o /dev/null "$url" 2>/dev/null; then
            echo "  PASS: $label is ready"
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo "  FAIL: $label did not respond at $url within ${timeout}s"
    return 1
}

_smoke_check_services() {
    local failures=0

    echo "Checking core service endpoints..."
    _smoke_wait_for_url "$SMD_READY_URL" "SMD" || failures=$((failures + 1))
    _smoke_wait_for_url "$BSS_READY_URL" "BSS" || failures=$((failures + 1))
    _smoke_wait_for_url "$CLOUD_INIT_URL" "cloud-init" || failures=$((failures + 1))
    _smoke_wait_for_url "$PCS_READY_URL" "PCS" || failures=$((failures + 1))
    _smoke_wait_for_url "$STORK_READY_URL" "Stork" || failures=$((failures + 1))

    return "$failures"
}

_smoke_check_minikube() {
    echo "Checking minikube-specific resources..."
    if minikube kubectl -- get pods -n ochami 2>/dev/null | grep -q "Running"; then
        echo "  PASS: minikube pods are running in ochami namespace"
        return 0
    else
        echo "  FAIL: No running pods found in ochami namespace"
        return 1
    fi
}

_smoke_check_docker_compose() {
    echo "Checking docker-compose-specific resources..."
    if docker compose ps 2>/dev/null | grep -q "Up\|running"; then
        echo "  PASS: docker compose services are running"
        return 0
    else
        echo "  FAIL: No running docker compose services found"
        return 1
    fi
}

_smoke_check_quadlets() {
    local failures=0

    echo "Checking quadlets-specific resources..."
    if systemctl is-active --quiet openchami.target 2>/dev/null; then
        echo "  PASS: openchami.target is active"
    else
        echo "  FAIL: openchami.target is not active"
        failures=$((failures + 1))
    fi

    if sudo podman ps 2>/dev/null | grep -q "ochami\|openchami"; then
        echo "  PASS: podman containers are running"
    else
        echo "  FAIL: No ochami podman containers found"
        failures=$((failures + 1))
    fi

    return "$failures"
}

# Main entry point: run_smoke_tests <method>
run_smoke_tests() {
    local method="$1"
    local failures=0

    echo ""
    echo "=== Smoke Tests for method: $method ==="

    # Core service checks (all methods)
    _smoke_check_services || failures=$((failures + $?))

    # Method-specific checks
    case "$method" in
        minikube)
            _smoke_check_minikube || failures=$((failures + 1))
            ;;
        docker-compose)
            _smoke_check_docker_compose || failures=$((failures + 1))
            ;;
        quadlets)
            _smoke_check_quadlets || failures=$((failures + $?))
            ;;
    esac

    if [ "$failures" -gt 0 ]; then
        echo "=== SMOKE TEST FAILED: $failures check(s) failed for $method ==="
        return 1
    fi

    echo "=== SMOKE TEST PASSED for $method ==="
    return 0
}
