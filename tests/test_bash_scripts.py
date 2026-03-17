"""Tests for scripts/ops/ bash scripts — verify they exist, are executable, and well-formed."""

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT / "scripts" / "ops"


class TestScriptsExist:
    """All required bash scripts must be present."""

    EXPECTED_SCRIPTS = [
        "lib/common.sh",
        "check-deps.sh",
        "create-test-vms.sh",
        "register-nodes.sh",
        "register-bss-defaults.sh",
        "health-check.sh",
        "teardown.sh",
        "lab-setup.sh",
        "deploy.sh",
        "build-images.sh",
    ]

    def test_all_scripts_exist(self):
        for script in self.EXPECTED_SCRIPTS:
            path = SCRIPTS_DIR / script
            assert path.is_file(), f"missing script: {script}"

    def test_all_scripts_are_executable(self):
        for script in self.EXPECTED_SCRIPTS:
            path = SCRIPTS_DIR / script
            assert os.access(path, os.X_OK), f"not executable: {script}"


class TestScriptStructure:
    """Verify scripts follow required conventions."""

    def _read_script(self, name: str) -> str:
        return (SCRIPTS_DIR / name).read_text()

    def test_common_sh_has_logging_functions(self):
        content = self._read_script("lib/common.sh")
        assert "log_info" in content
        assert "log_warn" in content
        assert "log_error" in content

    def test_common_sh_has_wait_for_url(self):
        content = self._read_script("lib/common.sh")
        assert "wait_for_url" in content

    def test_common_sh_has_secret_generation(self):
        content = self._read_script("lib/common.sh")
        assert "generate_secret" in content
        assert "ensure_secrets_file" in content

    def test_common_sh_has_bridge_carrier_helpers(self):
        content = self._read_script("lib/common.sh")
        assert "ensure_libvirt_network" in content
        assert "pxe-net" in content
        assert "virbr-pxe" in content
        assert "ensure_bridge_carrier" in content
        assert "remove_bridge_carrier_dummy" in content
        assert "disable_conflicting_dhcp_networks" in content
        assert "restore_conflicting_dhcp_networks" in content

    def test_common_sh_has_dry_run_support(self):
        content = self._read_script("lib/common.sh")
        assert "DRY_RUN" in content
        assert "run_cmd" in content

    def test_scripts_source_common(self):
        """All operational scripts should source lib/common.sh."""
        for name in ["check-deps.sh", "create-test-vms.sh", "health-check.sh", "teardown.sh",
                      "deploy.sh", "register-nodes.sh", "register-bss-defaults.sh"]:
            content = self._read_script(name)
            assert "common.sh" in content, f"{name} should source common.sh"

    def test_scripts_use_set_euo_pipefail(self):
        """common.sh sets strict mode; scripts source it."""
        content = self._read_script("lib/common.sh")
        assert "set -euo pipefail" in content

    def test_check_deps_supports_all_methods(self):
        content = self._read_script("check-deps.sh")
        assert "compose" in content
        assert "quadlets" in content
        assert "minikube" in content
        assert "check ss" in content
        assert "check ip" in content

    def test_teardown_supports_all_methods(self):
        content = self._read_script("teardown.sh")
        assert "compose" in content
        assert "quadlets" in content
        assert "minikube" in content

    def test_deploy_runs_all_steps(self):
        content = self._read_script("deploy.sh")
        assert "check-deps.sh" in content
        assert "health-check.sh" in content
        assert "register-bss-defaults.sh" in content
        assert "build-images.sh" in content

    def test_deploy_builds_images_before_services(self):
        content = self._read_script("deploy.sh")
        build_pos = content.index("build-images.sh")
        compose_up_pos = content.index("docker compose")
        assert build_pos < compose_up_pos, \
            "build-images.sh should run before docker compose up"

    def test_deploy_supports_skip_image_build(self):
        content = self._read_script("deploy.sh")
        assert "SKIP_IMAGE_BUILD" in content

    def test_register_nodes_uses_direct_smd_writes(self):
        content = self._read_script("register-nodes.sh")
        assert 'SMD_BASE_URL="https://' in content
        assert 'curl -skf' in content or 'curl -ksf' in content
        assert "SMD_PORT" in content

    def test_deploy_uses_managed_generated_compose_file(self):
        content = self._read_script("deploy.sh")
        assert "docker-compose.generated.yml" in content
        assert 'cp "$GENERATED" "$COMPOSE_FILE"' in content
        assert 'if [ ! -f "$COMPOSE_FILE" ]' not in content
        assert 'nix build .#deploy-profile' in content
        assert "envsubst" in content
        assert "--wait" in content
        assert "CHECK_KEA=true" in content
        assert ".tmp/openchami-secrets.env" in content
        assert "ensure_bridge_carrier" in content
        assert "disable_conflicting_dhcp_networks" in content

    def test_create_test_vms_bootstraps_libvirt_and_registration(self):
        content = self._read_script("create-test-vms.sh")
        assert "--count" in content
        assert "virt-install" in content
        assert "qemu-img" in content
        assert "register-nodes.sh" in content
        assert "register-bss-defaults.sh" in content
        assert "ochami-pxe-net" in content
        assert "virbr-ochami" in content
        assert "ensure_bridge_carrier" in content
        assert "docker compose" in content
        assert "--no-deps" in content
        assert "kea kea-sync" in content
        assert "kea-ctrl-agent" not in content
        assert "kea-sync" in content
        assert "health-check.sh" in content
        assert "/v1/sync" in content
        assert "/boot/v1/bootscript" in content
        assert "/apis/bss/boot/v1/bootscript" in content
        assert 'arch=x86_64' in content
        assert "kernel --name kernel" in content
        assert "initrd --name initrd" in content

    def test_lab_setup_uses_ochami_libvirt_names(self):
        content = self._read_script("lab-setup.sh")
        assert 'NETWORK_NAME="${NETWORK_NAME:-ochami-pxe-net}"' in content
        assert 'NETWORK_BRIDGE="${NETWORK_BRIDGE:-virbr-ochami}"' in content

    def test_teardown_uses_managed_generated_compose_file(self):
        content = self._read_script("teardown.sh")
        assert '$(dirname "$(dirname "$SCRIPT_DIR")")/ochami-docker-compose' in content
        assert "docker-compose.generated.yml" in content
        assert "remove_bridge_carrier_dummy" in content
        assert "restore_conflicting_dhcp_networks" in content

    def test_build_images_sources_common(self):
        content = self._read_script("build-images.sh")
        assert "common.sh" in content

    def test_build_images_builds_all_oci_images(self):
        content = self._read_script("build-images.sh")
        for img in ["oci-smd", "oci-bss", "oci-pcs", "oci-cloud-init",
                     "oci-http-server", "oci-tftp", "oci-kea", "oci-kea-sync"]:
            assert img in content, f"build-images.sh should build {img}"
        assert "KEA_SYNC_SRC" in content
        assert "--impure" in content
        assert "git@github.com:OpenCHAMI/kea-sync.git" in content
        assert "git clone --depth 1" in content

    def test_build_images_supports_runtime_flag(self):
        content = self._read_script("build-images.sh")
        assert "--runtime" in content
        assert "KEA_SYNC_SRC" in content

    def test_scripts_support_dry_run(self):
        for name in ["check-deps.sh", "health-check.sh", "teardown.sh",
                      "deploy.sh", "register-bss-defaults.sh"]:
            content = self._read_script(name)
            assert "dry-run" in content or "DRY_RUN" in content, \
                f"{name} should support --dry-run"

    def test_health_check_can_fail_when_kea_is_down(self):
        content = self._read_script("health-check.sh")
        assert 'KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"' in content
        assert "CHECK_KEA" in content
        assert "checking kea container health via docker compose" in content
        assert "ps --format json kea" in content
        assert "checking kea on UDP port" in content
        assert "ss -lun" in content
        assert "/readiness" in content
        assert "artifacts/opensuse/vmlinuz-lts" in content

    def test_register_bss_defaults_uses_generated_boot_artifacts(self):
        content = self._read_script("register-bss-defaults.sh")
        assert "nix build .#boot-artifacts" in content
        assert "kernel-params" in content
        assert "vmlinuz-lts" in content
        assert "initramfs-lts" in content
        assert "rootfs.squashfs" not in content

    def test_create_test_vms_uses_default_kea_sync_port(self):
        content = self._read_script("create-test-vms.sh")
        assert 'KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"' in content


class TestMakefileTargets:
    """Verify Makefile has the new operational targets."""

    def setup_method(self):
        self.content = (ROOT / "Makefile").read_text()

    def test_has_deploy_target(self):
        assert "deploy:" in self.content

    def test_has_teardown_target(self):
        assert "teardown:" in self.content

    def test_has_check_target(self):
        assert "check:" in self.content

    def test_has_generate_target(self):
        assert "generate:" in self.content

    def test_deploy_uses_method_variable(self):
        assert "$(METHOD)" in self.content

    def test_deploy_calls_script(self):
        assert "scripts/ops/deploy.sh" in self.content

    def test_has_build_images_target(self):
        assert "build-images:" in self.content
        assert "build-images.sh" in self.content

    def test_has_create_test_vms_target(self):
        assert "create-test-vms:" in self.content
        assert "create-test-vms.sh" in self.content

    def test_has_generate_images_target(self):
        assert "generate-images:" in self.content
        assert "nix build .#boot-artifacts" in self.content
