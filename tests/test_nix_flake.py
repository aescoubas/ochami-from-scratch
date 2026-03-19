from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_flake_exports_mcp_package() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")
    package_nix = (PROJECT_ROOT / "nix" / "package.nix").read_text(encoding="utf-8")

    assert "./nix/package.nix" in flake
    assert "buildPythonApplication" in package_nix
    assert "packages = {" in flake
    assert "default = mcpPackage" in flake
    assert "checks = {" in flake
    assert "devShells.default" in flake
    assert "/bin/ochami-mcp" in flake


def test_flake_has_mcp_and_lab_driver_apps() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")

    assert "apps = {" in flake
    assert "mcp = flake-utils.lib.mkApp" in flake
    assert '"lab-driver" = flake-utils.lib.mkApp' in flake


def test_flake_exports_generators_and_images() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")

    assert "docker-compose-yml" in flake
    assert "docker-compose-yml-dev" in flake
    assert "quadlet-units" in flake
    assert "quadlet-units-dev" in flake
    assert "helm-values" in flake
    assert "helm-values-dev" in flake
    assert "deploy-profile" in flake
    assert "deploy-profile-dev" in flake
    assert "lab-controller-system" in flake
    assert "lab-boot-node-system" in flake
    assert "lab-controller-vm" in flake
    assert "lab-boot-node-vm" in flake
    assert "oci-smd" in flake
    assert "oci-bss" in flake
    assert "oci-libvirt-bmc" in flake
    assert "oci-images" in flake
    assert "oci-images-dev" in flake


def test_flake_supports_local_image_tag_overrides() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")

    assert "SMD_IMAGE_TAG" in flake
    assert "BSS_IMAGE_TAG" in flake
    assert "PCS_IMAGE_TAG" in flake
    assert "CLOUD_INIT_IMAGE_TAG" in flake
    assert "KEA_SYNC_IMAGE_TAG" in flake


def test_readme_documents_nix_workflow() -> None:
    readme = (PROJECT_ROOT / "README.md").read_text(encoding="utf-8")

    assert "nix develop" in readme
    assert "nix build" in readme
    assert "SMD_SRC" in readme
    assert "BSS_SRC" in readme
    assert "PCS_SRC" in readme
    assert "CLOUD_INIT_SRC" in readme


def test_agents_documents_local_source_overrides() -> None:
    agents = (PROJECT_ROOT / "AGENTS.md").read_text(encoding="utf-8")

    assert "SMD_SRC" in agents
    assert "BSS_SRC" in agents
    assert "PCS_SRC" in agents
    assert "CLOUD_INIT_SRC" in agents
