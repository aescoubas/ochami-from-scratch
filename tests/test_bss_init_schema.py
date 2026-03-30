from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_bss_init_migration_target_is_consistent() -> None:
    """BSS_DBSTEP=2 must appear in the Helm chart."""
    helm = (PROJECT_ROOT / "deploy" / "helm" / "templates" / "bss-pod.yaml").read_text(encoding="utf-8")

    assert 'name: BSS_DBSTEP' in helm
    assert 'value: "2"' in helm
