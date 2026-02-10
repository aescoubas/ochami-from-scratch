#!/bin/bash
set -euo pipefail

# test_pcs_power.sh — End-to-end test for the PCS power-control chain:
#   PCS (port 28007) -> SMD (port 27779) -> Redfish Emulator (port 443)
#
# Usage: ./scripts/test_pcs_power.sh [--method METHOD] [COMPONENT_ID] [--verbose]
#   --method      Deployment method: minikube, docker-compose, podman (default: docker-compose)
#   COMPONENT_ID  Node xname to test (default: x0c0s0b0n0)
#   --verbose     Show raw JSON output on failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

# --- Argument Parsing ---
COMPONENT_ID="x0c0s0b0n0"
VERBOSE=false
METHOD="docker-compose"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --verbose) VERBOSE=true ;;
        --method) METHOD="$2"; shift ;;
        -h|--help)
            echo "Usage: $0 [--method METHOD] [COMPONENT_ID] [--verbose]"
            echo ""
            echo "End-to-end test for PCS power-control chain."
            echo ""
            echo "Options:"
            echo "  --method METHOD  Deployment method: minikube, docker-compose, podman"
            echo "                   (default: docker-compose)"
            echo "  --verbose        Show raw JSON output on failure"
            echo ""
            echo "Arguments:"
            echo "  COMPONENT_ID  Node xname to test (default: x0c0s0b0n0)"
            echo ""
            echo "Prerequisites:"
            echo "  - Deployment running via: ./deploy.sh --method <METHOD> --vms N"
            echo "  - curl and jq installed"
            exit 0
            ;;
        -*) error "Unknown option: $1"; exit 1 ;;
        *) COMPONENT_ID="$1" ;;
    esac
    shift
done

# Validate method
case "$METHOD" in
    minikube|docker-compose|podman) ;;
    *) error "Unknown method: $METHOD (expected minikube, docker-compose, or podman)"; exit 1 ;;
esac

# Derive BMC ID from component ID (e.g., x0c0s0b0n0 -> x0c0s0b0)
BMC_ID="${COMPONENT_ID%n*}"

# --- Prerequisites ---
require_command curl
require_command jq

HOST_IP="${HOST_IP:-192.168.100.2}"

# --- Resolve service URLs based on deployment method ---
if [ "$METHOD" = "minikube" ]; then
    require_command minikube
    echo "Resolving service IPs from Kubernetes (minikube)..."

    PCS_IP=$(minikube kubectl -- get svc ochami-pcs -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    SMD_IP=$(minikube kubectl -- get svc ochami-smd -n ochami -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)

    if [ -z "$PCS_IP" ]; then
        error "Could not determine PCS ClusterIP. Is the deployment running?"
        exit 1
    fi
    if [ -z "$SMD_IP" ]; then
        error "Could not determine SMD ClusterIP. Is the deployment running?"
        exit 1
    fi

    PCS_URL="http://${PCS_IP}:${PCS_PORT}"
    SMD_URL="http://${SMD_IP}:${SMD_PORT}"
elif [ "$METHOD" = "podman" ]; then
    # Podman Quadlet uses host networking — services are on localhost
    PCS_URL="http://localhost:${PCS_PORT}"
    SMD_URL="http://localhost:${SMD_PORT}"
else
    PCS_URL="http://${HOST_IP}:${PCS_PORT}"
    SMD_URL="http://${HOST_IP}:${SMD_PORT}"
fi

# --- Test Framework ---
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
declare -a TEST_RESULTS=()

run_test() {
    local test_num="$1"
    local test_name="$2"
    local test_func="$3"

    TESTS_RUN=$((TESTS_RUN + 1))
    printf "  [%d/7] %-40s " "$test_num" "$test_name"

    local output
    if output=$($test_func 2>&1); then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}PASS${NC}"
        TEST_RESULTS+=("PASS|$test_name")
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}FAIL${NC}"
        TEST_RESULTS+=("FAIL|$test_name")
        if [ "$VERBOSE" = true ] && [ -n "$output" ]; then
            echo "    $output"
        fi
    fi
}

# --- Test Functions ---

test_pcs_liveness() {
    local resp
    resp=$(curl -sf -o /dev/null -w "%{http_code}" "${PCS_URL}/liveness")
    if [ "$resp" -ge 200 ] && [ "$resp" -lt 300 ]; then
        return 0
    fi
    echo "HTTP $resp from PCS liveness"
    return 1
}

test_smd_endpoint() {
    local resp body
    body=$(curl -sf "${SMD_URL}/hsm/v2/Inventory/RedfishEndpoints/${BMC_ID}")
    local ep_id
    ep_id=$(echo "$body" | jq -r '.ID // empty')
    if [ "$ep_id" = "$BMC_ID" ]; then
        return 0
    fi
    echo "Expected endpoint $BMC_ID, got: $body"
    return 1
}

test_redfish_reachable() {
    # Get the emulator hostname from SMD's RedfishEndpoint
    local endpoint_body emulator_host
    endpoint_body=$(curl -sf "${SMD_URL}/hsm/v2/Inventory/RedfishEndpoints/${BMC_ID}")
    emulator_host=$(echo "$endpoint_body" | jq -r '.FQDN // .Hostname // empty')

    if [ -z "$emulator_host" ]; then
        echo "Could not determine emulator host from SMD endpoint"
        return 1
    fi

    local resp
    resp=$(curl -ksf -o /dev/null -w "%{http_code}" "https://${emulator_host}/redfish/v1/Systems/1")
    if [ "$resp" -ge 200 ] && [ "$resp" -lt 300 ]; then
        return 0
    fi
    echo "HTTP $resp from emulator at ${emulator_host}"
    return 1
}

test_power_status() {
    local body power_state error_msg
    body=$(curl -sf -X POST "${PCS_URL}/v1/power-status" \
        -H "Content-Type: application/json" \
        -d "{\"xname\":[\"${COMPONENT_ID}\"]}")
    error_msg=$(echo "$body" | jq -r '.status[0].error // empty')
    power_state=$(echo "$body" | jq -r '.status[0].powerState // empty')
    # Pass if PCS returned a response without an error (any power state is OK)
    if [ -z "$error_msg" ] && [ -n "$power_state" ]; then
        return 0
    fi
    echo "Power state: ${power_state:-empty}, error: ${error_msg:-none}, response: $body"
    return 1
}

test_force_off() {
    # Send force-off transition
    local resp transition_id
    resp=$(curl -sf -X POST "${PCS_URL}/v1/transitions" \
        -H "Content-Type: application/json" \
        -d "{\"operation\":\"force-off\",\"location\":[{\"xname\":\"${COMPONENT_ID}\"}]}")
    transition_id=$(echo "$resp" | jq -r '.transitionID // empty')

    if [ -z "$transition_id" ]; then
        echo "No transitionID in response: $resp"
        return 1
    fi

    # Poll for completion
    if ! poll_transition "$transition_id"; then
        echo "Transition $transition_id did not complete"
        return 1
    fi
    return 0
}

test_verify_off() {
    if ! poll_power_state "off"; then
        echo "Expected 'off' within timeout"
        return 1
    fi
    return 0
}

test_power_on_and_verify() {
    # Send on transition
    local resp transition_id
    resp=$(curl -sf -X POST "${PCS_URL}/v1/transitions" \
        -H "Content-Type: application/json" \
        -d "{\"operation\":\"on\",\"location\":[{\"xname\":\"${COMPONENT_ID}\"}]}")
    transition_id=$(echo "$resp" | jq -r '.transitionID // empty')

    if [ -z "$transition_id" ]; then
        echo "No transitionID in response: $resp"
        return 1
    fi

    # Poll for completion
    if ! poll_transition "$transition_id"; then
        echo "Transition $transition_id did not complete"
        return 1
    fi

    # Verify state is on
    if ! poll_power_state "on"; then
        echo "Expected 'on' within timeout"
        return 1
    fi
    return 0
}

# --- Helpers ---

poll_power_state() {
    local expected_state="$1"
    local max_attempts=20
    local interval=5

    for _attempt in $(seq 1 "$max_attempts"); do
        local body power_state
        body=$(curl -sf -X POST "${PCS_URL}/v1/power-status" \
            -H "Content-Type: application/json" \
            -d "{\"xname\":[\"${COMPONENT_ID}\"]}" 2>/dev/null) || true
        power_state=$(echo "$body" | jq -r '.status[0].powerState // empty')
        if [ "$power_state" = "$expected_state" ]; then
            return 0
        fi
        sleep "$interval"
    done
    echo "Last power state: ${power_state:-empty}"
    return 1
}

poll_transition() {
    local transition_id="$1"
    local max_attempts=30
    local interval=2

    for _attempt in $(seq 1 "$max_attempts"); do
        local resp status
        resp=$(curl -sf "${PCS_URL}/v1/transitions/${transition_id}" 2>/dev/null) || true

        if [ -z "$resp" ]; then
            sleep "$interval"
            continue
        fi

        status=$(echo "$resp" | jq -r '.transitionStatus // empty')
        case "$status" in
            completed)
                return 0
                ;;
            aborted)
                echo "Transition aborted: $resp"
                return 1
                ;;
            new|in-progress|"")
                sleep "$interval"
                ;;
            *)
                sleep "$interval"
                ;;
        esac
    done
    return 1
}

# --- Main ---

echo ""
echo "======================================"
echo " PCS Power Control — End-to-End Tests"
echo "======================================"
echo ""
echo "  Method:       $METHOD"
echo "  Target node:  $COMPONENT_ID"
echo "  BMC ID:       $BMC_ID"
echo "  PCS URL:      $PCS_URL"
echo "  SMD URL:      $SMD_URL"
echo ""

run_test 1 "PCS Liveness"                test_pcs_liveness
run_test 2 "SMD Endpoint Registered"      test_smd_endpoint
run_test 3 "Redfish Emulator Reachable"   test_redfish_reachable
run_test 4 "PCS Power Status Query"       test_power_status
run_test 5 "PCS Force-Off Transition"     test_force_off
run_test 6 "Verify Off State"            test_verify_off
run_test 7 "PCS On Transition + Verify"   test_power_on_and_verify

# --- Summary ---
echo ""
echo "======================================"
echo " Summary"
echo "======================================"
echo ""

for result in "${TEST_RESULTS[@]}"; do
    local_status="${result%%|*}"
    local_name="${result#*|}"
    if [ "$local_status" = "PASS" ]; then
        echo -e "  ${GREEN}PASS${NC}  $local_name"
    else
        echo -e "  ${RED}FAIL${NC}  $local_name"
    fi
done

echo ""
echo "  Total: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
echo ""

if [ "$TESTS_FAILED" -gt 0 ]; then
    error "$TESTS_FAILED test(s) failed."
    exit 1
fi

info "All tests passed!"
exit 0
