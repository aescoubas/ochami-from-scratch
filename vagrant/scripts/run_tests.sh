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

# --- Prepare log directory ---
mkdir -p "$LOG_DIR"

# --- Install prerequisites ---
echo "=== Installing prerequisites ==="
bash "$PROJECT_ROOT/scripts/install_prerequisites.sh" 2>&1 | tee "$LOG_DIR/${DISTRO}-prerequisites.log"
echo ""

# --- Run tests for each method ---
declare -A RESULTS
OVERALL_EXIT=0

for method in "${ALL_METHODS[@]}"; do
    LOG_FILE="$LOG_DIR/${DISTRO}-${method}.log"
    echo "=============================================="
    echo "  Testing method: $method on $DISTRO"
    echo "  Log: $LOG_FILE"
    echo "=============================================="

    method_rc=0

    # Deploy
    echo "--> Deploying with --method $method --mode hardware --vms 0 ..."
    if bash "$PROJECT_ROOT/deploy.sh" --method "$method" --mode hardware --vms 0 2>&1 | tee "$LOG_FILE"; then
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
        echo "--> Deploy FAILED"
        method_rc=1
    fi

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
