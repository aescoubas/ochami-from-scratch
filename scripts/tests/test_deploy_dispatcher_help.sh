#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SCRIPT="$PROJECT_ROOT/deploy.sh"

assert_contains_text() {
    local text="$1"
    local needle="$2"
    local message="$3"

    if [[ "$text" != *"$needle"* ]]; then
        echo "FAIL: $message"
        echo "  missing: $needle"
        exit 1
    fi
}

test_dispatcher_help_lists_forwarded_options() {
    local help_output
    help_output="$(bash "$DEPLOY_SCRIPT" --help)"

    assert_contains_text "$help_output" "--method METHOD" "deploy help should list method option"
    assert_contains_text "$help_output" "--orchestrator METHOD" "deploy help should list deprecated orchestrator alias"

    local common_options=(
        "--rebuild"
        "--dhcp-start"
        "--dhcp-end"
        "--dhcp-netmask"
        "--fail-on-conflict"
        "--auto-kill"
        "--set-fs-protected-regular"
        "--interface"
        "--ip"
        "--cidr"
        "--phy-iface"
        "--mode"
        "--vms"
        "--nodes-file"
        "--smd-ref"
        "--bss-ref"
        "--pcs-ref"
        "--smd-repo-uri"
        "--bss-repo-uri"
        "--pcs-repo-uri"
        "--discovery-method"
        "--magellan-subnets"
        "--magellan-hosts"
        "--magellan-subnet-mask"
        "--magellan-bmc-user"
        "--magellan-bmc-pass"
        "--magellan-bmc-id-map"
        "--magellan-cache"
        "--magellan-insecure"
    )

    local opt
    for opt in "${common_options[@]}"; do
        assert_contains_text "$help_output" "$opt" "deploy help should include forwarded option $opt"
    done
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_dispatcher_help_lists_forwarded_options
