"""Verify profile env files exist and contain required variables."""
import pathlib
import pytest

PROJECT = pathlib.Path(__file__).resolve().parent.parent

PROFILES = ["official", "dev", "cscs"]

REQUIRED_VARS = [
    "PROFILE_NAME", "IMAGE_PREFIX", "IMAGE_REGISTRY",
    "SMD_REF", "BSS_REF", "CLOUD_INIT_REF", "PCS_REF", "KEA_SYNC_REF",
    "SMD_REPO", "BSS_REPO", "PCS_REPO", "CLOUD_INIT_REPO", "KEA_SYNC_REPO",
    "POSTGRES_IMAGE",
    "SMD_PORT", "BSS_PORT", "POSTGRES_PORT",
]


class TestProfiles:
    @pytest.mark.parametrize("profile", PROFILES)
    def test_profile_exists(self, profile):
        env_file = PROJECT / "profiles" / f"{profile}.env"
        assert env_file.is_file(), f"Missing profile: {profile}.env"

    @pytest.mark.parametrize("profile", PROFILES)
    def test_profile_has_required_vars(self, profile):
        content = (PROJECT / "profiles" / f"{profile}.env").read_text()
        for var in REQUIRED_VARS:
            assert f"{var}=" in content, f"{profile}.env missing {var}"

    def test_official_has_pinned_refs(self):
        content = (PROJECT / "profiles" / "official.env").read_text()
        # Official should have version-pinned refs, not "main"
        for line in content.splitlines():
            if line.startswith("SMD_REF=") or line.startswith("BSS_REF="):
                assert "main" not in line, f"Official profile should pin {line.split('=')[0]}"

    def test_cscs_has_prefix_and_registry(self):
        content = (PROJECT / "profiles" / "cscs.env").read_text()
        assert 'IMAGE_PREFIX=cscs-' in content
        assert 'IMAGE_REGISTRY=' in content and 'jfrog' in content
