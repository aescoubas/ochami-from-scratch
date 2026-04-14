"""Tests for scripts/ops/ bash scripts — verify they exist, are executable, and well-formed."""

import os
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
        "push-boot-artifacts.sh",
        "health-check.sh",
        "teardown.sh",
        "lab-setup.sh",
        "deploy.sh",
        "build-images.sh",
        "build-boot-artifacts.sh",
        "lab.sh",
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

    def test_common_sh_has_docker_compose_helpers(self):
        content = self._read_script("lib/common.sh")
        assert "docker_compose_available" in content
        assert "docker_compose_label" in content
        assert "docker_daemon_reachable" in content
        assert "docker_compose()" in content

    def test_common_sh_has_secret_generation(self):
        content = self._read_script("lib/common.sh")
        assert "generate_secret" in content
        assert "ensure_secrets_file" in content
        assert 'LIBVIRT_BMC_USER=admin' in content
        assert 'LIBVIRT_BMC_PASSWORD=password' in content

    def test_common_sh_has_bridge_carrier_helpers(self):
        content = self._read_script("lib/common.sh")
        assert "ensure_libvirt_network" in content
        assert "ensure_bridge_carrier" in content
        assert "remove_bridge_carrier_dummy" in content

    def test_common_sh_has_dry_run_support(self):
        content = self._read_script("lib/common.sh")
        assert "DRY_RUN" in content
        assert "run_cmd" in content

    def test_common_sh_has_boot_image_metadata(self):
        content = self._read_script("lib/common.sh")
        assert "resolve_boot_image_metadata" in content

    def test_scripts_source_common(self):
        """All operational scripts should source lib/common.sh."""
        for name in ["check-deps.sh", "create-test-vms.sh", "health-check.sh", "teardown.sh",
                      "deploy.sh", "register-nodes.sh", "register-bss-defaults.sh",
                      "push-boot-artifacts.sh"]:
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
        assert "check ss" in content or "ss" in content
        assert "check ip" in content or "ip" in content
        assert "docker_daemon_reachable" in content
        assert "OPENCHAMI_ALLOW_UNSUPPORTED_DARWIN" in content

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
        assert "OPENCHAMI_TEST_NODE_IMAGE" in content

    def test_deploy_builds_images_before_services(self):
        content = self._read_script("deploy.sh")
        build_pos = content.index("build-images.sh")
        compose_up_pos = content.index("docker_compose")
        assert build_pos < compose_up_pos, \
            "build-images.sh should run before docker compose up"

    def test_deploy_builds_boot_artifacts_before_compose_start(self):
        content = self._read_script("deploy.sh")
        boot_artifacts_pos = content.index("build-boot-artifacts.sh")
        compose_up_pos = content.index("docker_compose -f")
        assert boot_artifacts_pos < compose_up_pos, \
            "boot artifacts should be built before docker compose up"

    def test_deploy_supports_skip_image_build(self):
        content = self._read_script("deploy.sh")
        assert "SKIP_IMAGE_BUILD" in content
        assert "PROFILE" in content

    def test_deploy_places_boot_artifacts_for_quadlets(self):
        content = self._read_script("deploy.sh")
        assert "/etc/openchami/artifacts" in content

    def test_register_nodes_uses_direct_smd_writes(self):
        content = self._read_script("register-nodes.sh")
        assert "SMD_PORT" in content
        assert "REDFISH_BMC_USER" in content
        assert "REDFISH_BMC_PASSWORD" in content
        assert "--xname" in content
        assert "--mac" in content
        assert "--ip" in content

    def test_deploy_uses_compose_artifacts(self):
        content = self._read_script("deploy.sh")
        assert "docker-compose.yml" in content
        assert "envsubst" in content
        assert "--wait" in content
        assert ".tmp/openchami-secrets.env" in content
        assert "ensure_bridge_carrier" in content
        assert "disable_conflicting_dhcp_networks" in content
        # Renders configs to staging directory, not in-place on committed files
        assert ".tmp/rendered-configs" in content
        assert "CONFIG_DIR}.templates" in content
        # Places boot artifacts for compose volume mount
        assert "boot artifacts placed at" in content
        assert "ARTIFACTS_DIR" in content

    def test_create_test_vms_bootstraps_libvirt_and_registration(self):
        content = self._read_script("create-test-vms.sh")
        assert 'METHOD="${METHOD:-compose}"' in content
        assert "--count" in content
        assert "virt-install" in content
        assert "qemu-img" in content
        assert "register-nodes.sh" in content
        assert "register-bss-defaults.sh" in content or "ensure_bss_defaults" in content
        assert 'LIBVIRT_BMC_IMAGE="${LIBVIRT_BMC_IMAGE:-localhost/libvirt-bmc:latest}"' in content
        assert 'EXPLICIT_LIBVIRT_BMC_USER="${LIBVIRT_BMC_USER:-}"' in content
        assert 'EXPLICIT_LIBVIRT_BMC_PASSWORD="${LIBVIRT_BMC_PASSWORD:-}"' in content
        assert "ochami-pxe-net" in content
        assert "virbr-ochami" in content
        assert "ensure_bridge_carrier" in content
        assert "docker_compose" in content
        assert "init_xname_layout" in content
        assert "bmc_xname_for_index" in content
        assert "xname_for_index" in content
        assert "domain_name_for_index" in content
        assert "bmc_ip_for_index" in content
        assert "domain_uuid" in content
        assert "ensure_compose_libvirt_bmc" in content
        assert "wait_for_compose_libvirt_bmc" in content
        assert "wait_for_component_endpoint" in content
        assert "wait_for_pcs_power_status" in content
        assert "console_ready_pattern_for_boot_image" in content
        assert "kea-sync" in content
        assert "/v1/sync" in content
        assert "/boot/v1/bootscript" in content
        assert "/apis/bss/boot/v1/bootscript" in content
        assert 'arch=x86_64' in content
        assert "kernel --name kernel" in content
        assert "initrd --name initrd" in content
        assert 'KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"' in content
        assert 'NETBOOT_CONSOLE_READY_PATTERN="${NETBOOT_CONSOLE_READY_PATTERN:-}"' in content
        assert "xname,mac,ip,bmc_ip,bmc_xname,domain" in content
        assert "register-nodes.sh" in content

    def test_lab_setup_uses_ochami_libvirt_names(self):
        content = self._read_script("lab-setup.sh")
        assert 'NETWORK_NAME="${NETWORK_NAME:-ochami-pxe-net}"' in content
        assert 'NETWORK_BRIDGE="${NETWORK_BRIDGE:-virbr-ochami}"' in content

    def test_boot_image_scripts_do_not_hardcode_opensuse_artifact_paths(self):
        register_defaults = self._read_script("register-bss-defaults.sh")
        health_check = self._read_script("health-check.sh")

        assert "resolve_boot_image_metadata" in register_defaults
        assert "resolve_boot_image_metadata" in health_check

    def test_teardown_uses_compose_artifacts(self):
        content = self._read_script("teardown.sh")
        assert "deploy/compose" in content
        assert "docker-compose.yml" in content
        assert '.tmp/openchami-secrets.env' in content
        assert 'ensure_secrets_file "$SECRETS_FILE"' in content
        assert '--env-file "$SECRETS_FILE"' in content
        assert 'LIBVIRT_BMC_CONTAINER_PREFIX="${LIBVIRT_BMC_CONTAINER_PREFIX:-ochami-libvirt-bmc}"' in content
        assert 'docker ps -a --filter "name=${LIBVIRT_BMC_CONTAINER_PREFIX}-"' in content
        assert "remove_bridge_carrier_dummy" in content
        assert "restore_conflicting_dhcp_networks" in content
        # Restores committed config templates after teardown
        assert "CONFIG_DIR}.templates" in content
        assert "restored committed config templates" in content
        assert ".tmp/rendered-configs" in content

    def test_build_images_sources_common(self):
        content = self._read_script("build-images.sh")
        assert "common.sh" in content

    def test_build_images_builds_all_services(self):
        content = self._read_script("build-images.sh")
        assert "PROFILE" in content
        assert "SMD" in content
        assert "BSS" in content
        assert "PCS" in content
        assert "CLOUD_INIT" in content
        assert "KEA_SYNC" in content
        assert "Dockerfile" in content

    def test_scripts_support_dry_run(self):
        for name in ["check-deps.sh", "health-check.sh", "teardown.sh",
                      "deploy.sh", "register-bss-defaults.sh"]:
            content = self._read_script(name)
            assert "dry-run" in content or "DRY_RUN" in content, \
                f"{name} should support --dry-run"

    def test_health_check_can_fail_when_kea_is_down(self):
        content = self._read_script("health-check.sh")
        assert "CHECK_KEA" in content
        assert "resolve_boot_image_metadata" in content

    def test_register_bss_defaults_uses_boot_artifacts(self):
        content = self._read_script("register-bss-defaults.sh")
        assert "resolve_boot_image_metadata" in content
        assert "ARTIFACT_BASE_URL" in content
        assert "--artifact-base-url" in content

    def test_create_test_vms_uses_default_kea_sync_port(self):
        content = self._read_script("create-test-vms.sh")
        assert 'KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"' in content


class TestMakefileTargets:
    """Verify Makefile has the operational targets."""

    def setup_method(self):
        self.content = (ROOT / "Makefile").read_text()

    def test_has_deploy_target(self):
        assert "deploy:" in self.content

    def test_has_teardown_target(self):
        assert "teardown:" in self.content

    def test_has_check_target(self):
        assert "check:" in self.content

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
        assert "--method $(METHOD)" in self.content

    def test_makefile_exposes_local_source_override_variables(self):
        for name in ["SMD_SRC", "BSS_SRC", "PCS_SRC", "CLOUD_INIT_SRC", "KEA_SYNC_SRC"]:
            assert f"{name} ?=" in self.content

    def test_makefile_forwards_local_source_override_variables(self):
        for name in ["SMD_SRC", "BSS_SRC", "PCS_SRC", "CLOUD_INIT_SRC", "KEA_SYNC_SRC"]:
            assert f'{name}="$({name})"' in self.content

    def test_has_test_target(self):
        assert "test:" in self.content
        assert "pytest" in self.content
