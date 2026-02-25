#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UBUNTU_PREREQ_SCRIPT="$PROJECT_ROOT/scripts/install_prerequisites.sh"
FEDORA_PREREQ_SCRIPT="$PROJECT_ROOT/scripts/install_prerequisites_fedora.sh"
BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_and_load_images.sh"
RUNNER_SCRIPT="$PROJECT_ROOT/vagrant/scripts/run_tests.sh"

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

test_ubuntu_prerequisites_install_minikube_and_helm() {
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'if ! command_exists minikube; then' \
        "Ubuntu prerequisites should install minikube when missing"
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'install minikube-linux-amd64 /usr/local/bin/minikube' \
        "Ubuntu prerequisites should install the minikube binary"
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'if ! command_exists helm; then' \
        "Ubuntu prerequisites should install helm when missing"
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'raw\.githubusercontent\.com/helm/helm/main/scripts/get-helm-3' \
        "Ubuntu prerequisites should install helm via the official installer script"
}

test_prerequisites_install_go_toolchain() {
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'if ! command_exists go; then' \
        "Ubuntu prerequisites should install Go when missing"
    assert_contains "$UBUNTU_PREREQ_SCRIPT" 'apt-get install -y golang-go' \
        "Ubuntu prerequisites should install golang-go"
    assert_contains "$FEDORA_PREREQ_SCRIPT" 'if ! command_exists go; then' \
        "Fedora prerequisites should install Go when missing"
    assert_contains "$FEDORA_PREREQ_SCRIPT" 'dnf install -y golang' \
        "Fedora prerequisites should install golang"
}

test_build_script_uses_project_root_anchored_paths() {
    assert_contains "$BUILD_SCRIPT" 'ARTIFACTS_DIR="\$PROJECT_ROOT/ochami-helm/http-server/artifacts"' \
        "build script should stage artifacts using PROJECT_ROOT-anchored path"
    assert_contains "$BUILD_SCRIPT" 'DOCKER_CONTEXT="\$PROJECT_ROOT/ochami-helm/http-server/"' \
        "build script should use PROJECT_ROOT-anchored context for http-server builds"
    assert_contains "$BUILD_SCRIPT" 'build_local_image "localhost/redfish-emulator:latest" "\$PROJECT_ROOT/ochami-helm/redfish-emulator/"' \
        "build script should use PROJECT_ROOT-anchored context for redfish-emulator builds"
}

test_vagrant_runner_enforces_cwd_safe_execution() {
    assert_contains "$RUNNER_SCRIPT" 'cd "\$PROJECT_ROOT"' \
        "vagrant runner should change cwd to PROJECT_ROOT before deployment loop"
    assert_contains "$RUNNER_SCRIPT" 'PXE_TEST_INTERFACE="\$\{PXE_TEST_INTERFACE:-ochami-pxe0\}"' \
        "vagrant runner should define a dedicated PXE test interface"
    assert_contains "$RUNNER_SCRIPT" '^ensure_test_pxe_interface\(\)' \
        "vagrant runner should define a helper to ensure the PXE interface exists"
    assert_contains "$RUNNER_SCRIPT" 'deploy_args=\(--method "\$method" --mode hardware --vms 0 --interface "\$PXE_TEST_INTERFACE"\)' \
        "vagrant runner should construct deploy args with explicit interface"
    assert_contains "$RUNNER_SCRIPT" 'deploy_args\+=\(--rebuild\)' \
        "vagrant runner should support forced rebuild for deterministic test runs"
    assert_contains "$RUNNER_SCRIPT" 'bash "\$PROJECT_ROOT/teardown\.sh" --method "\$method" -y' \
        "vagrant runner should teardown using project-root script path"
}

test_vagrant_runner_checks_method_specific_prerequisites() {
    assert_contains "$RUNNER_SCRIPT" '^check_method_prerequisites\(\)' \
        "vagrant runner should define a method-specific prerequisite checker"
    assert_contains "$RUNNER_SCRIPT" 'check_method_prerequisites "\$method"' \
        "vagrant runner should run prerequisite checks before each deployment"
    assert_contains "$RUNNER_SCRIPT" 'minikube method requires minikube' \
        "runner preflight should emit explicit guidance for missing minikube"
    assert_contains "$RUNNER_SCRIPT" 'minikube method requires helm' \
        "runner preflight should emit explicit guidance for missing helm"
    assert_contains "$RUNNER_SCRIPT" 'docker-compose method requires docker' \
        "runner preflight should emit explicit guidance for missing docker"
    assert_contains "$RUNNER_SCRIPT" 'requires go for local microservice builds' \
        "runner preflight should emit explicit guidance for missing Go"
}

run_test() {
    local test_name="$1"
    "$test_name"
    echo "PASS: $test_name"
}

run_test test_ubuntu_prerequisites_install_minikube_and_helm
run_test test_prerequisites_install_go_toolchain
run_test test_build_script_uses_project_root_anchored_paths
run_test test_vagrant_runner_enforces_cwd_safe_execution
run_test test_vagrant_runner_checks_method_specific_prerequisites
