#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VM_TEST_SCRIPT="$PROJECT_ROOT/libvirt/scripts/vm_tests.sh"

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

run_with_mocked_virsh() {
    local scenario="$1"
    local workdir
    workdir="$(mktemp -d)"
    local log_file="$workdir/virsh.log"
    local count_file="$workdir/net_info_count"
    local stdout_file="$workdir/stdout.log"
    local stderr_file="$workdir/stderr.log"
    local status_file="$workdir/status"
    echo "0" > "$count_file"

    cat > "$workdir/virsh" <<'EOF_VIRSH'
#!/bin/bash
set -euo pipefail

cmd="${1:-}"
shift || true

scenario="${MOCK_VIRSH_SCENARIO:-already-active}"
count_file="${MOCK_NET_INFO_COUNT_FILE:?}"
log_file="${MOCK_VIRSH_LOG:?}"
net_name="${LIBVIRT_NETWORK:-default}"

case "$cmd" in
    net-info)
        target="${1:-}"
        if [ "$scenario" = "missing-network" ]; then
            echo "error: failed to get network '$target'" >&2
            exit 1
        fi
        if [ "$target" != "$net_name" ]; then
            echo "error: unknown network '$target'" >&2
            exit 1
        fi
        count="$(cat "$count_file" 2>/dev/null || echo 0)"
        count=$((count + 1))
        echo "$count" > "$count_file"

        active="yes"
        case "$scenario" in
            already-active)
                active="yes"
                ;;
            inactive-then-start)
                if [ "$count" -le 2 ]; then
                    active="no"
                else
                    active="yes"
                fi
                ;;
            race-already-active-on-start)
                if [ "$count" -le 2 ]; then
                    active="no"
                else
                    active="yes"
                fi
                ;;
            still-inactive-after-start)
                active="no"
                ;;
            *)
                active="yes"
                ;;
        esac

        cat <<EOF_NET
Name:           ${target}
UUID:           00000000-0000-0000-0000-000000000000
Active:         ${active}
Persistent:     yes
Autostart:      no
Bridge:         virbr0
EOF_NET
        ;;
    net-start)
        echo "net-start ${1:-}" >> "$log_file"
        case "$scenario" in
            inactive-then-start)
                exit 0
                ;;
            race-already-active-on-start)
                echo "error: Requested operation is not valid: network is already active" >&2
                exit 1
                ;;
            still-inactive-after-start)
                echo "error: Failed to start network" >&2
                exit 1
                ;;
            already-active)
                echo "error: Requested operation is not valid: network is already active" >&2
                exit 1
                ;;
            *)
                echo "error: unexpected net-start scenario" >&2
                exit 1
                ;;
        esac
        ;;
    net-autostart)
        echo "net-autostart ${1:-}" >> "$log_file"
        exit 0
        ;;
    net-list)
        cat <<EOF_LIST
 Name      State      Autostart   Persistent
---------------------------------------------
 default   active     yes         yes
EOF_LIST
        ;;
    *)
        echo "error: unsupported virsh command '$cmd'" >&2
        exit 1
        ;;
esac
EOF_VIRSH
    chmod +x "$workdir/virsh"

    (
        set +e
        export PATH="$workdir:$PATH"
        export LIBVIRT_NETWORK="default"
        export MOCK_VIRSH_SCENARIO="$scenario"
        export MOCK_NET_INFO_COUNT_FILE="$count_file"
        export MOCK_VIRSH_LOG="$log_file"

        source "$VM_TEST_SCRIPT"
        ensure_libvirt_network
    ) >"$stdout_file" 2>"$stderr_file"
    local status=$?
    echo "$status" > "$status_file"

    echo "$workdir"
}

test_vm_runner_is_sourceable_for_unit_tests() {
    assert_contains "$VM_TEST_SCRIPT" '^if \[\[ "\$\{BASH_SOURCE\[0\]\}" == "\$0" \]\]; then' \
        "vm_tests.sh should guard main execution when sourced"
}

test_network_already_active_does_not_start_again() {
    local workdir
    workdir="$(run_with_mocked_virsh "already-active")"
    local status
    status="$(cat "$workdir/status")"

    if [ "$status" -ne 0 ]; then
        echo "FAIL: already-active network should succeed"
        cat "$workdir/stderr.log"
        exit 1
    fi

    assert_not_contains "$workdir/virsh.log" '^net-start ' \
        "already-active network should skip net-start"
}

test_network_start_race_is_non_fatal_when_network_becomes_active() {
    local workdir
    workdir="$(run_with_mocked_virsh "race-already-active-on-start")"
    local status
    status="$(cat "$workdir/status")"

    if [ "$status" -ne 0 ]; then
        echo "FAIL: net-start race (already active) should be non-fatal"
        cat "$workdir/stderr.log"
        exit 1
    fi

    assert_contains "$workdir/virsh.log" '^net-start default$' \
        "race scenario should attempt net-start once"
}

test_network_inactive_starts_successfully() {
    local workdir
    workdir="$(run_with_mocked_virsh "inactive-then-start")"
    local status
    status="$(cat "$workdir/status")"

    if [ "$status" -ne 0 ]; then
        echo "FAIL: inactive network should start successfully"
        cat "$workdir/stderr.log"
        exit 1
    fi

    assert_contains "$workdir/virsh.log" '^net-start default$' \
        "inactive network should invoke net-start"
}

test_network_start_failure_still_fails_if_inactive_after_recheck() {
    local workdir
    workdir="$(run_with_mocked_virsh "still-inactive-after-start")"
    local status
    status="$(cat "$workdir/status")"

    if [ "$status" -eq 0 ]; then
        echo "FAIL: inactive network after start failure should remain fatal"
        exit 1
    fi

    assert_contains "$workdir/stderr.log" "failed to start libvirt network 'default'" \
        "fatal start failure should include clear error"
    assert_contains "$workdir/stderr.log" "libvirt network diagnostics for 'default'" \
        "fatal start failure should include diagnostics banner"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_vm_runner_is_sourceable_for_unit_tests
run_test test_network_already_active_does_not_start_again
run_test test_network_start_race_is_non_fatal_when_network_becomes_active
run_test test_network_inactive_starts_successfully
run_test test_network_start_failure_still_fails_if_inactive_after_recheck
