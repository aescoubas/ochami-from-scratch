#!/bin/bash
# smoke_test.sh — Health-check library for OpenCHAMI integration tests
# Source this file, then call: run_smoke_tests <method>

# Default timeout for service readiness (seconds)
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-120}"
SMOKE_INTERVAL="${SMOKE_INTERVAL:-3}"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SMOKE_HOST_IP="${SMOKE_HOST_IP:-192.168.100.2}"

# Service endpoints (relative to localhost)
SMD_READY_URL="http://localhost:27779/hsm/v2/service/ready"
BSS_READY_URL="http://localhost:27778/boot/v1/bootparameters"
CLOUD_INIT_URL="http://localhost:27777/cloud-init/version"
PCS_READY_URL="http://localhost:28007/liveness"
STORK_READY_URL="http://localhost:28010/api/version"
SMD_PROXY_COMPONENTS_URL="http://localhost/hsm/v2/State/Components"

_smoke_wait_for_bootscript() {
    local url="$1"
    local timeout="${2:-$SMOKE_TIMEOUT}"
    local interval="${3:-$SMOKE_INTERVAL}"
    local elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if curl -s -f "$url" 2>/dev/null | grep -q '/artifacts/opensuse/vmlinuz-lts'; then
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    return 1
}

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

_smoke_check_boot_artifacts() {
    local failures=0
    local artifact_urls=(
        "http://localhost/artifacts/opensuse/vmlinuz-lts"
        "http://localhost/artifacts/opensuse/initramfs-lts"
        "http://localhost/artifacts/opensuse/rootfs.squashfs"
        "http://localhost/artifacts/ubuntu/rootfs.squashfs"
    )

    echo "Checking boot artifact reachability through HTTP server..."
    local url
    for url in "${artifact_urls[@]}"; do
        if curl -s -f -I -o /dev/null "$url" 2>/dev/null; then
            echo "  PASS: artifact reachable: $url"
        else
            echo "  FAIL: artifact not reachable: $url"
            failures=$((failures + 1))
        fi
    done

    if curl -s -f "http://localhost/boot.ipxe" 2>/dev/null | grep -q '/artifacts/opensuse/vmlinuz-lts'; then
        echo "  PASS: /boot.ipxe references boot artifacts"
    else
        echo "  FAIL: /boot.ipxe does not reference expected artifact paths"
        failures=$((failures + 1))
    fi

    return "$failures"
}

_smoke_check_bss_smd_integration() {
    local method="$1"
    local failures=0
    local cli_python="$PROJECT_ROOT/.venv/bin/python"
    if [ ! -x "$cli_python" ]; then
        cli_python="python3"
    fi
    local log_file="/tmp/ochami-smoke-register-${method}.log"
    local mac ip component_id nid bmc_ip bmc_user bmc_pass bootscript_url

    case "$method" in
        minikube)
            mac="02:00:00:00:10:10"
            ip="192.168.100.210"
            component_id="x9000c0s0b0n0"
            nid="9000"
            bmc_ip="192.0.2.10"
            ;;
        docker-compose)
            mac="02:00:00:00:10:11"
            ip="192.168.100.211"
            component_id="x9000c0s1b0n0"
            nid="9001"
            bmc_ip="192.0.2.11"
            ;;
        quadlets)
            mac="02:00:00:00:10:12"
            ip="192.168.100.212"
            component_id="x9000c0s2b0n0"
            nid="9002"
            bmc_ip="192.0.2.12"
            ;;
        *)
            echo "  FAIL: unsupported method for BSS/SMD integration test: $method"
            return 1
            ;;
    esac

    bmc_user="${SMOKE_TEST_BMC_USER:-root}"
    bmc_pass="${SMOKE_TEST_BMC_PASS:-smoke-pass}"
    bootscript_url="http://localhost/boot/v1/bootscript?mac=${mac}"

    echo "Checking BSS/SMD integration via hardware registration flow..."

    if "$cli_python" -m ochami.cli register-node \
        --method "$method" \
        --host-ip "$SMOKE_HOST_IP" \
        --mac "$mac" \
        --ip "$ip" \
        --component-id "$component_id" \
        --nid "$nid" \
        --bmc-ip "$bmc_ip" \
        --bmc-user "$bmc_user" \
        --bmc-pass "$bmc_pass" \
        >"$log_file" 2>&1; then
        echo "  PASS: registration request completed ($component_id)"
    else
        echo "  FAIL: registration request failed for $component_id"
        echo "       log: $log_file"
        tail -n 20 "$log_file" || true
        return 1
    fi

    local elapsed=0
    local smd_registered=false
    while [ "$elapsed" -lt "$SMOKE_TIMEOUT" ]; do
        if curl -s -f "$SMD_PROXY_COMPONENTS_URL" 2>/dev/null \
            | jq -e --arg id "$component_id" '.Components // [] | any(.ID == $id)' >/dev/null; then
            smd_registered=true
            break
        fi
        sleep "$SMOKE_INTERVAL"
        elapsed=$((elapsed + SMOKE_INTERVAL))
    done

    if [ "$smd_registered" = true ]; then
        echo "  PASS: SMD contains registered component ($component_id)"
    else
        echo "  FAIL: SMD did not report component ($component_id) through /hsm/v2/State/Components"
        failures=$((failures + 1))
    fi

    if _smoke_wait_for_bootscript "$bootscript_url"; then
        echo "  PASS: BSS bootscript lookup succeeded for $mac"
    else
        echo "  FAIL: BSS bootscript lookup failed for $mac at $bootscript_url"
        failures=$((failures + 1))
    fi

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
    _smoke_check_boot_artifacts || failures=$((failures + $?))
    _smoke_check_bss_smd_integration "$method" || failures=$((failures + $?))

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
