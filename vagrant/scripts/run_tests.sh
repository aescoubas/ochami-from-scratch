#!/bin/bash
set -euo pipefail

# run_tests.sh — Main test orchestrator for OpenCHAMI integration tests
# Runs inside the Vagrant VM. Iterates over deployment methods, deploying,
# running smoke tests, and tearing down each one.
#
# Usage:
#   sudo ./vagrant/scripts/run_tests.sh              # Run all methods for this distro
#   sudo ./vagrant/scripts/run_tests.sh quadlets      # Run only the quadlets method

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="/tmp/ochami-test-logs"

# Source smoke test library
# shellcheck source=smoke_test.sh
source "$SCRIPT_DIR/smoke_test.sh"

# --- Distro detection ---
DISTRO="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    case "$ID" in
        ubuntu|debian) DISTRO="ubuntu" ;;
        fedora)        DISTRO="fedora" ;;
        *)             DISTRO="$ID" ;;
    esac
fi
echo "Detected distro: $DISTRO"

# --- Build method list ---
case "$DISTRO" in
    ubuntu)
        ALL_METHODS=("minikube" "docker-compose")
        ;;
    fedora)
        ALL_METHODS=("minikube" "docker-compose" "quadlets")
        ;;
    *)
        echo "Warning: Unknown distro '$DISTRO', defaulting to minikube + docker-compose"
        ALL_METHODS=("minikube" "docker-compose")
        ;;
esac

# Filter to a single method if argument provided
FILTER_METHOD="${1:-}"
if [ -n "$FILTER_METHOD" ]; then
    found=false
    for m in "${ALL_METHODS[@]}"; do
        if [ "$m" = "$FILTER_METHOD" ]; then
            found=true
            break
        fi
    done
    if ! $found; then
        echo "Error: Method '$FILTER_METHOD' is not valid for $DISTRO." >&2
        echo "Available methods: ${ALL_METHODS[*]}" >&2
        exit 1
    fi
    ALL_METHODS=("$FILTER_METHOD")
fi

echo "Methods to test: ${ALL_METHODS[*]}"
echo ""
PXE_TEST_INTERFACE="${PXE_TEST_INTERFACE:-ochami-pxe0}"
REBUILD_LOCAL_IMAGES="${REBUILD_LOCAL_IMAGES:-true}"

require_binary() {
    local binary="$1"
    local message="$2"

    if command -v "$binary" >/dev/null 2>&1; then
        return 0
    fi

    echo "ERROR: $message (missing binary: $binary)"
    return 1
}

check_method_prerequisites() {
    local method="$1"

    require_binary go "$method method requires go for local microservice builds" || return 1

    case "$method" in
        minikube)
            require_binary minikube "minikube method requires minikube" || return 1
            require_binary helm "minikube method requires helm" || return 1
            require_binary docker "minikube method requires docker" || return 1
            ;;
        docker-compose)
            require_binary docker "docker-compose method requires docker" || return 1
            if ! docker compose version >/dev/null 2>&1; then
                echo "ERROR: docker-compose method requires docker compose plugin"
                return 1
            fi
            ;;
        quadlets)
            require_binary podman "quadlets method requires podman" || return 1
            require_binary systemctl "quadlets method requires systemctl" || return 1
            ;;
        *)
            echo "ERROR: unsupported method '$method'"
            return 1
            ;;
    esac

    return 0
}

ensure_test_pxe_interface() {
    local iface="$1"

    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo "Creating test PXE interface: $iface"
        ip link add "$iface" type dummy
    fi

    ip link set "$iface" up
}

# --- Prepare log directory ---
mkdir -p "$LOG_DIR"

# --- Install prerequisites ---
echo "=== Installing prerequisites ==="
bash "$PROJECT_ROOT/scripts/install_prerequisites.sh" 2>&1 | tee "$LOG_DIR/${DISTRO}-prerequisites.log"
echo ""

cd "$PROJECT_ROOT"

# --- Run tests for each method ---
declare -A RESULTS
OVERALL_EXIT=0
first_method=true

for method in "${ALL_METHODS[@]}"; do
    LOG_FILE="$LOG_DIR/${DISTRO}-${method}.log"
    echo "=============================================="
    echo "  Testing method: $method on $DISTRO"
    echo "  Log: $LOG_FILE"
    echo "=============================================="

    method_rc=0

    echo "--> Ensuring test PXE interface '$PXE_TEST_INTERFACE' exists..."
    if ensure_test_pxe_interface "$PXE_TEST_INTERFACE" 2>&1 | tee "$LOG_FILE"; then
        echo "--> PXE test interface is ready"
    else
        echo "--> PXE test interface setup FAILED"
        method_rc=1
    fi

    # Method-specific preflight
    echo "--> Running method preflight checks..."
    if [ "$method_rc" -eq 0 ] && check_method_prerequisites "$method" 2>&1 | tee -a "$LOG_FILE"; then
        echo "--> Preflight checks passed"
    else
        if [ "$method_rc" -eq 0 ]; then
            echo "--> Preflight checks FAILED"
            method_rc=1
        fi
    fi

    # Deploy
    if [ "$method_rc" -eq 0 ]; then
        deploy_args=(--method "$method" --mode hardware --vms 0 --interface "$PXE_TEST_INTERFACE")
        if [ "$first_method" = true ] && [ "$REBUILD_LOCAL_IMAGES" = "true" ]; then
            deploy_args+=(--rebuild)
        fi
        echo "--> Deploying with ${deploy_args[*]} ..."
    fi
    if [ "$method_rc" -eq 0 ] && bash "$PROJECT_ROOT/deploy.sh" "${deploy_args[@]}" 2>&1 | tee -a "$LOG_FILE"; then
        echo "--> Deploy succeeded"

        # Smoke test
        echo "--> Running smoke tests..."
        if run_smoke_tests "$method" 2>&1 | tee -a "$LOG_FILE"; then
            echo "--> Smoke tests passed"
        else
            echo "--> Smoke tests FAILED"
            method_rc=1
        fi
    else
        if [ "$method_rc" -eq 0 ]; then
            echo "--> Deploy FAILED"
            method_rc=1
        fi
    fi

    first_method=false

    # Teardown (always runs, even on failure)
    echo "--> Tearing down method $method ..."
    bash "$PROJECT_ROOT/teardown.sh" --method "$method" -y 2>&1 | tee -a "$LOG_FILE" || true
    echo "--> Teardown complete"
    echo ""

    if [ "$method_rc" -ne 0 ]; then
        RESULTS[$method]="FAIL"
        OVERALL_EXIT=1
    else
        RESULTS[$method]="PASS"
    fi
done

# --- Summary ---
echo ""
echo "=============================================="
echo "  Test Summary ($DISTRO)"
echo "=============================================="
printf "  %-20s %s\n" "Method" "Result"
printf "  %-20s %s\n" "------" "------"
for method in "${ALL_METHODS[@]}"; do
    printf "  %-20s %s\n" "$method" "${RESULTS[$method]}"
done
echo "=============================================="

if [ "$OVERALL_EXIT" -ne 0 ]; then
    echo "OVERALL: FAILED (see logs in $LOG_DIR)"
else
    echo "OVERALL: PASSED"
fi

exit "$OVERALL_EXIT"
