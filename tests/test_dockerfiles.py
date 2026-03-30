"""Verify Dockerfiles exist and have correct structure."""
import pathlib
import pytest

PROJECT = pathlib.Path(__file__).resolve().parent.parent

EXPECTED_IMAGES = [
    "smd", "bss", "pcs", "cloud-init", "kea-sync",
    "kea", "http-server", "tftp", "libvirt-bmc", "redfish-emulator",
]

GO_SERVICES = ["smd", "bss", "pcs", "cloud-init", "kea-sync"]


class TestDockerfiles:
    @pytest.mark.parametrize("service", EXPECTED_IMAGES)
    def test_dockerfile_exists(self, service):
        dockerfile = PROJECT / "images" / service / "Dockerfile"
        assert dockerfile.is_file(), f"Missing Dockerfile for {service}"

    @pytest.mark.parametrize("service", GO_SERVICES)
    def test_go_service_uses_multistage(self, service):
        content = (PROJECT / "images" / service / "Dockerfile").read_text()
        assert content.count("FROM ") >= 2, f"{service} should use multi-stage build"
        assert "golang:" in content, f"{service} should use golang base"

    @pytest.mark.parametrize("service", GO_SERVICES)
    def test_go_service_has_source_args(self, service):
        content = (PROJECT / "images" / service / "Dockerfile").read_text()
        assert "SOURCE_REF" in content, f"{service} should accept SOURCE_REF build arg"

    def test_pcs_has_patch(self):
        patch_dir = PROJECT / "images" / "pcs" / "patches"
        assert patch_dir.is_dir(), "PCS should have patches directory"
        patches = list(patch_dir.glob("*.patch"))
        assert len(patches) > 0, "PCS should have at least one patch file"
