from __future__ import annotations

from pathlib import Path
import tomllib


def test_legacy_shell_entrypoints_removed() -> None:
    project_root = Path(__file__).resolve().parents[1]
    assert not (project_root / "deploy.sh").exists()
    assert not (project_root / "teardown.sh").exists()
    assert not (project_root / "scripts").exists()


def test_makefile_uses_pytest() -> None:
    project_root = Path(__file__).resolve().parents[1]
    content = (project_root / "Makefile").read_text(encoding="utf-8")
    assert ".venv/bin/python -m pytest" in content


def test_cli_entrypoint_renamed_to_ochamifs() -> None:
    project_root = Path(__file__).resolve().parents[1]
    pyproject = tomllib.loads((project_root / "pyproject.toml").read_text(encoding="utf-8"))
    scripts = pyproject["project"]["scripts"]
    assert "ochamifs" in scripts
    assert "ochami" not in scripts
