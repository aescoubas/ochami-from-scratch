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
        "kea.nix",
        "http-server.nix",
        "tftp.nix",
        "kea-sync.nix",
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

    def test_has_real_hashes(self):
        """Go service images must have real (non-fakeHash) source and vendor hashes."""
        for name in self.GO_SERVICES:
            content = (IMAGES_DIR / name).read_text()
            assert "fakeHash" not in content, \
                f"{name} should use real hashes, not lib.fakeHash"
            assert "sha256-" in content, \
                f"{name} should contain real sha256 hashes"


class TestUtilityImages:
    """Utility images (non-Go) should use dockerTools."""

    UTILITY = ["kea.nix", "http-server.nix", "tftp.nix", "redfish-emulator.nix"]

    def test_uses_docker_tools(self):
        for name in self.UTILITY:
            content = (IMAGES_DIR / name).read_text()
            assert "dockerTools.buildLayeredImage" in content, \
                f"{name} should use dockerTools.buildLayeredImage"


class TestParameterizedSourcePaths:
    """kea-sync and redfish-emulator use parameterized source paths."""

    def test_kea_sync_uses_parameter(self):
        content = (IMAGES_DIR / "kea-sync.nix").read_text()
        assert "keaSyncSrc" in content, "kea-sync.nix should accept keaSyncSrc parameter"
        assert 'builtins.getEnv "KEA_SYNC_SRC"' in content, \
            "kea-sync.nix should allow KEA_SYNC_SRC to point at the sibling service workspace"
        assert "buildGoModule" in content, "kea-sync.nix should build the Go service"
        assert "vendorHash" in content, "kea-sync.nix should pin vendored dependencies"
        assert "local-src/kea-sync" not in content, \
            "kea-sync.nix should not vendor private source inside this repository"
    def test_redfish_emulator_uses_parameter(self):
        content = (IMAGES_DIR / "redfish-emulator.nix").read_text()
        assert "emulatorSrc" in content, "redfish-emulator.nix should accept emulatorSrc parameter"
        assert "../../../" not in content, "redfish-emulator.nix should not use relative paths"


class TestFlakeExportsOciImages:
    """Verify flake.nix references all OCI image packages."""

    def setup_method(self):
        self.flake = (ROOT / "flake.nix").read_text()

    def test_exports_go_service_images(self):
        for name in ["oci-smd", "oci-bss", "oci-pcs", "oci-cloud-init"]:
            assert name in self.flake, f"flake.nix should export {name}"

    def test_exports_utility_images(self):
        for name in ["oci-http-server", "oci-tftp", "oci-kea", "oci-kea-sync", "oci-redfish-emulator"]:
            assert name in self.flake, f"flake.nix should export {name}"

    def test_passes_source_paths_to_images(self):
        assert '"oci-kea-sync" = pkgs.callPackage ./nix/images/kea-sync.nix' in self.flake
        assert '"oci-kea" = pkgs.callPackage ./nix/images/kea.nix' in self.flake
        assert "emulatorSrc = ./ochami-helm/redfish-emulator" in self.flake

    def test_passes_local_image_overrides_to_generators(self):
        assert "localImageOverrides" in self.flake


class TestKeaImage:
    """Verify the custom Kea image structure."""

    def test_kea_image_uses_nixpkgs_kea_and_http_tools(self):
        content = (IMAGES_DIR / "kea.nix").read_text()
        assert "pkgs.kea" in content
        assert "dockerTools.buildLayeredImage" in content
        assert "pkgs.curl" in content
        assert "var/lib/kea" in content


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

    def test_controller_exposes_ssh_for_host_orchestration(self):
        content = (ROOT / "nix" / "lab" / "controller.nix").read_text()
        assert "services.openssh" in content

    def test_secrets_has_deterministic_passwords(self):
        content = (ROOT / "nix" / "lab" / "secrets.nix").read_text()
        assert "test-postgres-password" in content
        assert "test-smd-password" in content

    def test_smoke_test_checks_podman(self):
        content = (ROOT / "nix" / "tests" / "lab-smoke.nix").read_text()
        assert "podman" in content
