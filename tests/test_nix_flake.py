from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_flake_exports_mcp_package() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")
    package_nix = (PROJECT_ROOT / "nix" / "package.nix").read_text(encoding="utf-8")

    assert "./nix/package.nix" in flake
    assert "buildPythonApplication" in package_nix
    assert "packages.default" in flake
    assert "checks.default" in flake
    assert "devShells.default" in flake
    assert "/bin/ochami-mcp" in flake


def test_flake_has_mcp_and_lab_driver_apps() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")

    assert "apps = {" in flake
    assert "mcp = flake-utils.lib.mkApp" in flake
    assert "lab-driver = flake-utils.lib.mkApp" in flake


def test_flake_exports_generators_and_images() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")

    assert "docker-compose-yml" in flake
    assert "quadlet-units" in flake
    assert "helm-values" in flake
    assert "deploy-profile" in flake
    assert "oci-smd" in flake
    assert "oci-bss" in flake


def test_readme_documents_nix_workflow() -> None:
    readme = (PROJECT_ROOT / "README.md").read_text(encoding="utf-8")

    assert "nix develop" in readme
    assert "nix build" in readme
