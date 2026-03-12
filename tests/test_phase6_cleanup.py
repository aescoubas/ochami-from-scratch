from __future__ import annotations

from pathlib import Path
import tomllib


def test_legacy_python_cli_removed() -> None:
    """The monolithic Python CLI modules are gone."""
    project_root = Path(__file__).resolve().parents[1]
    assert not (project_root / "ochami" / "cli.py").exists()
    assert not (project_root / "ochami" / "deploy").exists()
    assert not (project_root / "ochami" / "teardown").exists()
    assert not (project_root / "ochami" / "config.py").exists()
    assert not (project_root / "ochami" / "defaults.py").exists()
    assert not (project_root / "ochami" / "build.py").exists()


def test_hand_written_deployment_artifacts_removed() -> None:
    """Hand-written compose/quadlet files are replaced by Nix generators."""
    project_root = Path(__file__).resolve().parents[1]
    assert not (project_root / "ochami-docker-compose" / "docker-compose.yml").exists()
    assert not (project_root / "ochami-quadlets" / "containers" / "smd.container").exists()
    assert not (project_root / "templates" / "shared").exists()


def test_mcp_server_preserved() -> None:
    """MCP server module is preserved as standalone."""
    project_root = Path(__file__).resolve().parents[1]
    assert (project_root / "ochami" / "mcp" / "server.py").is_file()
    assert (project_root / "ochami" / "mcp" / "openchami_api.py").is_file()


def test_mcp_entrypoint_in_pyproject() -> None:
    project_root = Path(__file__).resolve().parents[1]
    pyproject = tomllib.loads((project_root / "pyproject.toml").read_text(encoding="utf-8"))
    scripts = pyproject["project"]["scripts"]
    assert "ochami-mcp" in scripts
    assert "ochamifs" not in scripts


def test_nix_generators_exist() -> None:
    """Nix generators are the replacement for hand-written artifacts."""
    project_root = Path(__file__).resolve().parents[1]
    assert (project_root / "nix" / "generators" / "docker-compose.nix").is_file()
    assert (project_root / "nix" / "generators" / "quadlets.nix").is_file()
    assert (project_root / "nix" / "generators" / "helm-values.nix").is_file()


def test_bash_scripts_exist() -> None:
    """Bash scripts are the replacement for Python deployers."""
    project_root = Path(__file__).resolve().parents[1]
    assert (project_root / "scripts" / "ops" / "deploy.sh").is_file()
    assert (project_root / "scripts" / "ops" / "teardown.sh").is_file()
    assert (project_root / "scripts" / "ops" / "check-deps.sh").is_file()


def test_makefile_has_new_targets() -> None:
    project_root = Path(__file__).resolve().parents[1]
    content = (project_root / "Makefile").read_text(encoding="utf-8")
    assert "python -m pytest" in content
    assert "deploy:" in content
    assert "teardown:" in content
    assert "check:" in content
