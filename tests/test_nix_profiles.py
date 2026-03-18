"""Tests for Nix profile manifests and profile-scoped outputs."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class TestProfileFiles:
    """The repo should expose explicit official/dev stack profiles."""

    def test_profile_files_exist(self):
        for relpath in [
            "nix/profiles/official.nix",
            "nix/profiles/dev.nix",
            "nix/profiles/resolve.nix",
            "nix/services/catalog.nix",
        ]:
            assert (ROOT / relpath).is_file(), f"missing {relpath}"

    def test_official_profile_pins_release_refs(self):
        official = (ROOT / "nix" / "profiles" / "official.nix").read_text()

        assert 'bss = "v1.32.2";' in official
        assert 'smd = "v2.19.2";' in official
        assert 'cloudInit = "v1.4.0";' in official
        assert 'keaSync = "main";' in official
        assert 'pcs = "main";' in official
        assert 'httpServer = "latest";' in official
        assert 'tftp = "latest";' in official

    def test_dev_profile_tracks_main_refs(self):
        dev = (ROOT / "nix" / "profiles" / "dev.nix").read_text()

        assert 'bss = "main";' in dev
        assert 'smd = "main";' in dev
        assert 'cloudInit = "main";' in dev
        assert 'keaSync = "main";' in dev
        assert 'pcs = "main";' in dev
        assert 'httpServer = "latest";' in dev
        assert 'tftp = "latest";' in dev


class TestProfileAwareFlakeOutputs:
    """The flake should export both profile-specific and defaulted outputs."""

    def test_flake_exports_profile_specific_outputs(self):
        flake = (ROOT / "flake.nix").read_text()

        for name in [
            "docker-compose-yml-dev",
            "quadlet-units-dev",
            "deploy-profile-dev",
            "helm-values-dev",
            "oci-images-dev",
            "oci-images-official",
        ]:
            assert name in flake, f"flake.nix should export {name}"

    def test_flake_defaults_unqualified_outputs_to_official(self):
        flake = (ROOT / "flake.nix").read_text()

        assert 'profilePackages.official."docker-compose-yml"' in flake
        assert 'profilePackages.dev."docker-compose-yml"' in flake
        assert 'profilePackages.official."quadlet-units"' in flake
        assert 'profilePackages.official."deploy-profile"' in flake


class TestProfileAwareImages:
    """Local image definitions should derive their tags from the selected ref."""

    def test_local_tag_names_are_not_hard_coded(self):
        for relpath in [
            "nix/images/smd.nix",
            "nix/images/bss.nix",
            "nix/images/pcs.nix",
            "nix/images/cloud-init.nix",
            "nix/images/kea-sync.nix",
            "nix/services/defaults.nix",
        ]:
            content = (ROOT / relpath).read_text()
            assert "local-smd" not in content
            assert "local-bss" not in content
            assert "local-pcs" not in content
            assert "local-cloud-init" not in content

    def test_resolve_profile_builds_localhost_image_refs(self):
        content = (ROOT / "nix" / "profiles" / "resolve.nix").read_text()

        assert 'localhost/smd:${profile.refs.smd}' in content
        assert 'localhost/bss:${profile.refs.bss}' in content
        assert 'localhost/cloud-init:${profile.refs.cloudInit}' in content
        assert 'localhost/pcs:${profile.refs.pcs}' in content
        assert 'localhost/kea-sync:${profile.refs.keaSync}' in content
        assert 'localhost/http-server:${profile.refs.httpServer}' in content
        assert 'localhost/tftp:${profile.refs.tftp}' in content
