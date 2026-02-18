#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_and_load_images.sh"

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

test_mksquashfs_has_containerized_fallback() {
    assert_contains "$BUILD_SCRIPT" 'if command_exists mksquashfs; then' \
        "build script should use host mksquashfs when available"
    assert_contains "$BUILD_SCRIPT" '\$CONTAINER_TOOL run --rm' \
        "build script should provide containerized mksquashfs fallback"
    assert_contains "$BUILD_SCRIPT" 'custom-image-builder-sles' \
        "containerized mksquashfs fallback should reuse the builder image"
    assert_contains "$BUILD_SCRIPT" 'mksquashfs /input /output/rootfs\.squashfs' \
        "containerized fallback should produce rootfs.squashfs in the workspace"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_vmlinuz_search_is_robust_for_macos_layouts
run_test test_mksquashfs_has_containerized_fallback
