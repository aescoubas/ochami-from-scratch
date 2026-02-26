#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/common.sh"

SUDO_BUILD_CAPTURED=""

sudo() {
    if [ "${1:-}" != "podman" ]; then
        echo "FAIL: unexpected sudo invocation: $*"
        return 1
    fi
    shift

    if [ "${1:-}" = "image" ] && [ "${2:-}" = "exists" ]; then
        if [ "${3:-}" = "$IMAGE_KEA_SIDECAR" ]; then
            return 1
        fi
        return 0
    fi

    if [ "${1:-}" = "build" ]; then
        SUDO_BUILD_CAPTURED="podman $*"
        return 0
    fi

    if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
        return 0
    fi

    if [ "${1:-}" = "tag" ]; then
        return 0
    fi

    return 0
}

docker() {
    return 0
}

minikube() {
    return 0
}

test_quadlets_build_images_supports_prefixed_container_tool() {
    SUDO_BUILD_CAPTURED=""

    if ! build_images_if_needed "sudo podman" "quadlets" "false" >/tmp/openchami-test-common-container-tool.log 2>&1; then
        echo "FAIL: build_images_if_needed should support prefixed container tool commands"
        cat /tmp/openchami-test-common-container-tool.log
        rm -f /tmp/openchami-test-common-container-tool.log
        return 1
    fi
    rm -f /tmp/openchami-test-common-container-tool.log

    if [[ "$SUDO_BUILD_CAPTURED" != *"podman build"* ]]; then
        echo "FAIL: quadlets image build should run through prefixed container tool"
        echo "  captured: $SUDO_BUILD_CAPTURED"
        return 1
    fi

    if [[ "$SUDO_BUILD_CAPTURED" != *"-t $IMAGE_KEA_SIDECAR"* ]]; then
        echo "FAIL: quadlets image build should target kea-sidecar image"
        echo "  captured: $SUDO_BUILD_CAPTURED"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    if "$test_name"; then
        echo "PASS: $test_name"
    else
        exit 1
    fi
}

run_test test_quadlets_build_images_supports_prefixed_container_tool
