"""Tests for nix/images/*.nix OCI image build definitions."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IMAGES_DIR = ROOT / "nix" / "images"


class TestImageFilesExist:
    """All OCI image Nix files must be present."""

    EXPECTED = [
        "smd.nix",
        "bss.nix",
        "pcs.nix",
        "cloud-init.nix",
        "http-server.nix",
        "tftp.nix",
        "kea-sidecar.nix",
        "redfish-emulator.nix",
    ]

    def test_all_image_nix_files_exist(self):
        for name in self.EXPECTED:
            assert (IMAGES_DIR / name).is_file(), f"missing {name}"


class TestGoServiceImages:
    """Go service images follow the fetchFromGitHub + buildGoModule pattern."""

    GO_SERVICES = ["smd.nix", "bss.nix", "pcs.nix", "cloud-init.nix"]

    def test_uses_fetch_from_github(self):
        for name in self.GO_SERVICES:
            content = (IMAGES_DIR / name).read_text()
            assert "fetchFromGitHub" in content, f"{name} should use fetchFromGitHub"

    def test_uses_build_go_module(self):
        for name in self.GO_SERVICES:
            content = (IMAGES_DIR / name).read_text()
            assert "buildGoModule" in content, f"{name} should use buildGoModule"

    def test_uses_docker_tools(self):
        for name in self.GO_SERVICES:
            content = (IMAGES_DIR / name).read_text()
            assert "dockerTools.buildLayeredImage" in content, \
                f"{name} should use dockerTools.buildLayeredImage"

    def test_uses_fake_hash_for_dev(self):
        for name in self.GO_SERVICES:
            content = (IMAGES_DIR / name).read_text()
            assert "fakeHash" in content, \
                f"{name} should use lib.fakeHash (update with real hashes to build)"


class TestUtilityImages:
    """Utility images (non-Go) should use dockerTools."""

    UTILITY = ["http-server.nix", "tftp.nix", "kea-sidecar.nix", "redfish-emulator.nix"]

    def test_uses_docker_tools(self):
        for name in self.UTILITY:
            content = (IMAGES_DIR / name).read_text()
            assert "dockerTools.buildLayeredImage" in content, \
                f"{name} should use dockerTools.buildLayeredImage"


class TestFlakeExportsOciImages:
    """Verify flake.nix references all OCI image packages."""

    def setup_method(self):
        self.flake = (ROOT / "flake.nix").read_text()

    def test_exports_go_service_images(self):
        for name in ["oci-smd", "oci-bss", "oci-pcs", "oci-cloud-init"]:
            assert name in self.flake, f"flake.nix should export {name}"

    def test_exports_utility_images(self):
        for name in ["oci-http-server", "oci-tftp", "oci-kea-sidecar", "oci-redfish-emulator"]:
            assert name in self.flake, f"flake.nix should export {name}"


class TestLabFiles:
    """Verify lab support files exist."""

    def test_secrets_nix_exists(self):
        assert (ROOT / "nix" / "lab" / "secrets.nix").is_file()

    def test_images_nix_exists(self):
        assert (ROOT / "nix" / "lab" / "images.nix").is_file()

    def test_controller_has_podman(self):
        content = (ROOT / "nix" / "lab" / "controller.nix").read_text()
        assert "podman" in content

    def test_controller_has_increased_memory(self):
        content = (ROOT / "nix" / "lab" / "controller.nix").read_text()
        assert "2048" in content

    def test_secrets_has_deterministic_passwords(self):
        content = (ROOT / "nix" / "lab" / "secrets.nix").read_text()
        assert "test-postgres-password" in content
        assert "test-smd-password" in content

    def test_smoke_test_checks_podman(self):
        content = (ROOT / "nix" / "tests" / "lab-smoke.nix").read_text()
        assert "podman" in content
