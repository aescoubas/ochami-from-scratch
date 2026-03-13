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

    def test_common_sh_has_dry_run_support(self):
        content = self._read_script("lib/common.sh")
        assert "DRY_RUN" in content
        assert "run_cmd" in content

    def test_scripts_source_common(self):
        """All operational scripts should source lib/common.sh."""
        for name in ["check-deps.sh", "health-check.sh", "teardown.sh",
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

    def test_build_images_sources_common(self):
        content = self._read_script("build-images.sh")
        assert "common.sh" in content

    def test_build_images_builds_all_oci_images(self):
        content = self._read_script("build-images.sh")
        for img in ["oci-smd", "oci-bss", "oci-pcs", "oci-cloud-init",
                     "oci-http-server", "oci-tftp", "oci-kea-sidecar"]:
            assert img in content, f"build-images.sh should build {img}"

    def test_build_images_supports_runtime_flag(self):
        content = self._read_script("build-images.sh")
        assert "--runtime" in content

    def test_scripts_support_dry_run(self):
        for name in ["check-deps.sh", "health-check.sh", "teardown.sh",
                      "deploy.sh", "register-bss-defaults.sh"]:
            content = self._read_script(name)
            assert "dry-run" in content or "DRY_RUN" in content, \
                f"{name} should support --dry-run"


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
