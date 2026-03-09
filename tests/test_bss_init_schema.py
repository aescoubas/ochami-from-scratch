from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_bss_init_migration_target_is_consistent_across_deployments() -> None:
    quadlet = (PROJECT_ROOT / "ochami-quadlets" / "containers" / "bss-init.container").read_text(encoding="utf-8")
    compose = (PROJECT_ROOT / "ochami-docker-compose" / "docker-compose.yml").read_text(encoding="utf-8")
    helm = (PROJECT_ROOT / "ochami-helm" / "templates" / "bss-pod.yaml").read_text(encoding="utf-8")

    assert "BSS_DBSTEP=3" in quadlet
    assert "BSS_DBSTEP: \"3\"" in compose
    assert 'name: BSS_DBSTEP' in helm
    assert 'value: "3"' in helm
