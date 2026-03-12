from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_flake_exports_vm_lab_targets() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")
    lab_test = (PROJECT_ROOT / "nix" / "tests" / "lab-smoke.nix").read_text(encoding="utf-8")

    assert "lab-smoke" in flake
    assert "lab-driver" in flake
    assert "testers.nixosTest" in lab_test
    assert "controller" in lab_test
    assert "bootnode" in lab_test


def test_lab_vm_modules_exist() -> None:
    controller = PROJECT_ROOT / "nix" / "lab" / "controller.nix"
    bootnode = PROJECT_ROOT / "nix" / "lab" / "boot-node.nix"

    assert controller.exists()
    assert bootnode.exists()
