from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from ochami.config import DeployConfig, DeploymentMethod
from ochami.state import AppliedState, config_hash, load_state, needs_apply, save_state


def _make_config(**overrides: object) -> DeployConfig:
    defaults = {"method": DeploymentMethod.DOCKER_COMPOSE}
    defaults.update(overrides)
    return DeployConfig(**defaults)


# ── config_hash ────────────────────────────────────────────────────


def test_config_hash_is_deterministic() -> None:
    cfg = _make_config()
    assert config_hash(cfg) == config_hash(cfg)


def test_config_hash_same_across_instances() -> None:
    a = _make_config()
    b = _make_config()
    assert config_hash(a) == config_hash(b)


def test_config_hash_changes_on_field_change() -> None:
    a = _make_config(pxe_ip="192.168.100.2")
    b = _make_config(pxe_ip="10.0.0.1")
    assert config_hash(a) != config_hash(b)


def test_config_hash_changes_on_method_change() -> None:
    a = _make_config(method=DeploymentMethod.DOCKER_COMPOSE)
    b = _make_config(method=DeploymentMethod.MINIKUBE)
    assert config_hash(a) != config_hash(b)


def test_config_hash_is_hex_sha256() -> None:
    h = config_hash(_make_config())
    assert len(h) == 64
    assert all(c in "0123456789abcdef" for c in h)


# ── save_state / load_state ────────────────────────────────────────


def test_save_load_round_trip(tmp_path: Path) -> None:
    state_path = tmp_path / ".openchami-state.yaml"
    state = AppliedState(config_hash="abc123", method="docker-compose", timestamp="2024-01-01T00:00:00")

    save_state(state_path, state)
    loaded = load_state(state_path)

    assert loaded is not None
    assert loaded.config_hash == "abc123"
    assert loaded.method == "docker-compose"
    assert loaded.timestamp == "2024-01-01T00:00:00"


def test_load_state_missing_file(tmp_path: Path) -> None:
    state_path = tmp_path / "does-not-exist.yaml"
    assert load_state(state_path) is None


def test_load_state_corrupt_file(tmp_path: Path) -> None:
    state_path = tmp_path / ".openchami-state.yaml"
    state_path.write_text("not: valid: yaml: [[[")
    assert load_state(state_path) is None


def test_load_state_empty_file(tmp_path: Path) -> None:
    state_path = tmp_path / ".openchami-state.yaml"
    state_path.write_text("")
    assert load_state(state_path) is None


def test_load_state_missing_keys(tmp_path: Path) -> None:
    state_path = tmp_path / ".openchami-state.yaml"
    state_path.write_text(yaml.dump({"config_hash": "abc"}))
    assert load_state(state_path) is None


def test_save_state_creates_yaml(tmp_path: Path) -> None:
    state_path = tmp_path / ".openchami-state.yaml"
    state = AppliedState(config_hash="def456", method="minikube", timestamp="2024-06-15T12:00:00")

    save_state(state_path, state)

    raw = yaml.safe_load(state_path.read_text())
    assert raw["config_hash"] == "def456"
    assert raw["method"] == "minikube"
    assert raw["timestamp"] == "2024-06-15T12:00:00"


# ── needs_apply ────────────────────────────────────────────────────


def test_needs_apply_no_saved_state() -> None:
    assert needs_apply("abc123", None) is True


def test_needs_apply_matching_hash() -> None:
    saved = AppliedState(config_hash="abc123", method="docker-compose", timestamp="t")
    assert needs_apply("abc123", saved) is False


def test_needs_apply_different_hash() -> None:
    saved = AppliedState(config_hash="abc123", method="docker-compose", timestamp="t")
    assert needs_apply("xyz789", saved) is True
