"""Tests for the Nix deploy profile."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_deploy_profile_service_definitions_exist():
    """All service definition files exist under nix/services/."""
    services_dir = ROOT / "nix" / "services"
    expected = [
        "defaults.nix",
        "postgres.nix",
        "smd.nix",
        "bss.nix",
        "cloud-init.nix",
        "pcs.nix",
        "kea.nix",
        "nginx.nix",
        "tftp.nix",
    ]
    for filename in expected:
        assert (services_dir / filename).is_file(), f"missing {filename}"


def test_deploy_profile_nix_exists():
    """The deploy profile builder exists."""
    assert (ROOT / "nix" / "deploy" / "profile.nix").is_file()


def test_defaults_nix_matches_python_defaults():
    """Verify that nix/services/defaults.nix ports match ochami/defaults.py."""
    defaults_nix = (ROOT / "nix" / "services" / "defaults.nix").read_text()
    # Check critical port values are present.
    assert "smd = 27779" in defaults_nix
    assert "bss = 27778" in defaults_nix
    assert "postgres = 15432" in defaults_nix
    assert "http = 80" in defaults_nix
    assert "cloudInit = 27777" in defaults_nix
    assert "pcs = 28007" in defaults_nix
    assert "keaSync = 28080" in defaults_nix


def test_defaults_nix_has_all_databases():
    """Verify all database entries are defined."""
    defaults_nix = (ROOT / "nix" / "services" / "defaults.nix").read_text()
    for db in ["hmsds", "bssdb", "kea", "pcsdb", "stork"]:
        assert db in defaults_nix, f"missing database {db}"


def test_defaults_nix_has_all_secret_keys():
    """Verify all secret keys are listed."""
    defaults_nix = (ROOT / "nix" / "services" / "defaults.nix").read_text()
    for key in [
        "POSTGRES_PASSWORD",
        "SMD_DB_PASSWORD",
        "BSS_DB_PASSWORD",
        "KEA_DB_PASSWORD",
        "PCS_DB_PASSWORD",
        "STORK_DB_PASSWORD",
    ]:
        assert key in defaults_nix, f"missing secret key {key}"


def test_defaults_nix_uses_private_kea_sync_checkout_url():
    """The kea-sync source metadata should use the private SSH checkout URL."""
    defaults_nix = (ROOT / "nix" / "services" / "defaults.nix").read_text()
    assert 'keaSync = "git@github.com:OpenCHAMI/kea-sync.git"' in defaults_nix


def test_flake_exports_deploy_profile():
    """Verify flake.nix references the deploy profile."""
    flake = (ROOT / "flake.nix").read_text()
    assert "deploy-profile" in flake
    assert "nix/deploy/profile.nix" in flake


def test_flake_exports_boot_artifacts():
    """Verify flake.nix exports the generated boot artifacts package."""
    flake = (ROOT / "flake.nix").read_text()
    assert "boot-artifacts" in flake
    assert "nix/boot-artifacts.nix" in flake


def test_deploy_profile_defaults_to_virbr_ochami_interface():
    """The deploy profile should default to the VM lab PXE bridge."""
    profile = (ROOT / "nix" / "deploy" / "profile.nix").read_text()
    assert 'pxeInterface ? "virbr-ochami"' in profile


def test_all_services_have_required_fields():
    """Verify each service .nix file defines the expected structure."""
    services_dir = ROOT / "nix" / "services"
    # Each service file should reference defaults and define at least one
    # service with a name, image, and type.
    for filename in ["postgres.nix", "smd.nix", "bss.nix", "cloud-init.nix",
                     "pcs.nix", "kea.nix", "nginx.nix", "tftp.nix"]:
        content = (services_dir / filename).read_text()
        assert "defaults" in content, f"{filename} should reference defaults"
        assert "name =" in content, f"{filename} should define service name"
        assert "image" in content or "configFiles" in content, \
            f"{filename} should define image or configFiles"
