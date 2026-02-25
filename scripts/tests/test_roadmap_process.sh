#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
    local message="$1"
    echo "FAIL: $message"
    exit 1
}

assert_file_exists() {
    local file="$1"
    local description="$2"

    if [ ! -f "$file" ]; then
        fail "$description (missing: $file)"
    fi
}

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

test_roadmap_file_exists() {
    assert_file_exists "$PROJECT_ROOT/ROADMAP.md" \
        "ROADMAP.md must exist at the repository root"
}

test_agents_and_roadmap_contract() {
    assert_contains "$PROJECT_ROOT/AGENTS.md" 'ROADMAP\.md' \
        "AGENTS.md should reference ROADMAP.md"
    assert_contains "$PROJECT_ROOT/ROADMAP.md" '^# ' \
        "ROADMAP.md should define a top-level heading"
    assert_contains "$PROJECT_ROOT/ROADMAP.md" '^## ' \
        "ROADMAP.md should define at least one section"
    assert_contains "$PROJECT_ROOT/ROADMAP.md" '^- \[[ x]\] ' \
        "ROADMAP.md should contain trackable checklist items"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_roadmap_file_exists
run_test test_agents_and_roadmap_contract
