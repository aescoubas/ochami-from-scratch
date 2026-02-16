#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/common.sh"

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "FAIL: $msg"
        echo "  expected to contain: $needle"
        echo "  actual: $haystack"
        return 1
    fi
}

test_run_magellan_discovery_composes_commands() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN

    local log_file="$tmpdir/magellan.log"
    local fake_bin="$tmpdir/bin"
    mkdir -p "$fake_bin"

    cat > "$fake_bin/magellan" <<'EOF'
#!/bin/bash
set -euo pipefail
log_file="${MAGELLAN_TEST_LOG:?}"
echo "$*" >> "$log_file"
if [ "$1" = "collect" ]; then
    echo '{"inventory":"ok"}'
fi
EOF
    chmod +x "$fake_bin/magellan"

    export PATH="$fake_bin:$PATH"
    export MAGELLAN_TEST_LOG="$log_file"
    export ORCHESTRATOR="docker-compose"

    DISCOVERY_METHOD="magellan"
    MAGELLAN_SUBNETS="172.16.0.0/24,10.20.0.0/16"
    MAGELLAN_HOSTS="https://10.0.0.10,10.0.0.11"
    MAGELLAN_SUBNET_MASK="255.255.255.0"
    MAGELLAN_BMC_USER="admin"
    MAGELLAN_BMC_PASS="password"
    MAGELLAN_BMC_ID_MAP="@/tmp/id-map.yaml"
    MAGELLAN_CACHE="$tmpdir/assets.db"
    MAGELLAN_INSECURE="true"

    run_magellan_discovery "192.168.100.2"

    local calls
    calls="$(cat "$log_file")"
    assert_contains "$calls" "scan --cache $tmpdir/assets.db --subnet 172.16.0.0/24 --subnet 10.20.0.0/16 --subnet-mask 255.255.255.0 --insecure https://10.0.0.10 10.0.0.11" "scan command composition"
    assert_contains "$calls" "collect --cache $tmpdir/assets.db --show --format json --username admin --password password --bmc-id-map @/tmp/id-map.yaml --insecure" "collect command composition"
    assert_contains "$calls" "send -d @" "send data flag composition"
    assert_contains "$calls" "http://192.168.100.2:27779" "send target composition"
}

run_test() {
    local test_name="$1"
    if "$test_name"; then
        echo "PASS: $test_name"
    else
        exit 1
    fi
}

run_test test_run_magellan_discovery_composes_commands
