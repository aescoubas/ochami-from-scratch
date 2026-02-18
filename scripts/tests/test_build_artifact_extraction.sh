#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_and_load_images.sh"
MACOS_PREREQ_SCRIPT="$PROJECT_ROOT/scripts/install_prerequisites_macos.sh"

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

test_vmlinuz_search_is_robust_for_macos_layouts() {
    assert_contains "$BUILD_SCRIPT" '\$CONTAINER_TOOL cp "\$CONTAINER_ID:/lib/modules" \./modules_tmp' \
        "build script should copy /lib/modules when searching vmlinuz"
    assert_contains "$BUILD_SCRIPT" '\$CONTAINER_TOOL cp "\$CONTAINER_ID:/usr/lib/modules" \./usr_modules_tmp 2>/dev/null' \
        "build script should copy /usr/lib/modules when searching vmlinuz"
    assert_contains "$BUILD_SCRIPT" 'KERNEL_PATTERNS=\("vmlinuz\*" "Image\*" "bzImage\*" "linux\*" "kernel\*"\)' \
        "build script should search architecture-specific kernel naming variants"
    assert_contains "$BUILD_SCRIPT" 'find -L "\$search_dir" -type f -name "\$pattern"' \
        "build script should follow symlinks while searching kernel artifacts"
    assert_contains "$BUILD_SCRIPT" 'find -L "\$search_dir" -type f -name "vmlinux\*"' \
        "build script should include vmlinux fallback search"
    assert_contains "$BUILD_SCRIPT" 'for search_dir in "\$\{VMLINUZ_SEARCH_DIRS\[@\]\}"' \
        "build script should iterate over initialized vmlinuz search directories"
    assert_contains "$BUILD_SCRIPT" 'Searched directories: \$\{VMLINUZ_SEARCH_DIRS\[\*\]\}' \
        "build script should report the same vmlinuz search directories on failure"
    assert_not_contains "$BUILD_SCRIPT" '\bVMLINUX\b' \
        "build script should consistently use the VMLINUZ variable name"
}

test_mksquashfs_is_host_requirement_with_macos_brew_install() {
    assert_contains "$BUILD_SCRIPT" 'require_command mksquashfs' \
        "build script should require host mksquashfs"
    assert_not_contains "$BUILD_SCRIPT" '\$CONTAINER_TOOL run --rm' \
        "build script should not use containerized mksquashfs fallback"
    assert_contains "$BUILD_SCRIPT" 'sudo mksquashfs "\$BUILD_DIR/full_root" \./rootfs\.squashfs' \
        "build script should create squashfs directly on host"

    assert_contains "$MACOS_PREREQ_SCRIPT" 'brew install squashfs' \
        "macOS prerequisites should install squashfs via brew"
    assert_contains "$MACOS_PREREQ_SCRIPT" 'command_exists mksquashfs' \
        "macOS prerequisites should check for mksquashfs"
}

test_docker_build_loads_images_for_minikube() {
    assert_contains "$BUILD_SCRIPT" 'build_local_image\(\)' \
        "build script should define a helper to ensure local images exist after build"
    assert_contains "$BUILD_SCRIPT" 'docker image inspect "\$image"' \
        "build helper should verify image exists in local docker daemon"
    assert_contains "$BUILD_SCRIPT" 'docker buildx build --load' \
        "build helper should retry with buildx --load when docker build does not load image"
    assert_contains "$BUILD_SCRIPT" 'build_local_image "localhost/http-server:latest"' \
        "http-server image should be built via the robust helper"
    assert_contains "$BUILD_SCRIPT" 'build_local_image "localhost/redfish-emulator:latest"' \
        "redfish emulator image should be built via the robust helper"
    assert_contains "$BUILD_SCRIPT" 'docker save "localhost/http-server:latest" \| minikube image load -' \
        "http-server minikube load should stream tarball to avoid daemon context mismatches"
    assert_contains "$BUILD_SCRIPT" 'docker save "localhost/redfish-emulator:latest" \| minikube image load -' \
        "redfish minikube load should stream tarball to avoid daemon context mismatches"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_vmlinuz_search_is_robust_for_macos_layouts
run_test test_mksquashfs_is_host_requirement_with_macos_brew_install
run_test test_docker_build_loads_images_for_minikube
