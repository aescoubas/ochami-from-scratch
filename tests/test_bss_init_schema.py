from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_bss_init_migration_target_is_consistent() -> None:
    """BSS_DBSTEP=2 must appear in Nix service definition and Helm chart."""
    bss_nix = (PROJECT_ROOT / "nix" / "services" / "bss.nix").read_text(encoding="utf-8")
    helm = (PROJECT_ROOT / "ochami-helm" / "templates" / "bss-pod.yaml").read_text(encoding="utf-8")

    assert 'BSS_DBSTEP = "2"' in bss_nix
    assert 'name: BSS_DBSTEP' in helm
    assert 'value: "2"' in helm
