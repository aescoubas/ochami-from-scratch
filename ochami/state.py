from __future__ import annotations

import dataclasses
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import yaml

from ochami.config import DeployConfig


def config_hash(config: DeployConfig) -> str:
    """Return a deterministic SHA-256 hex digest of the config."""
    data = dataclasses.asdict(config)
    # Path objects are not JSON-serializable; convert to str
    for key, value in data.items():
        if isinstance(value, Path):
            data[key] = str(value)
    canonical = json.dumps(data, sort_keys=True, default=str)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


@dataclass(slots=True)
class AppliedState:
    config_hash: str
    method: str
    timestamp: str


def load_state(path: Path) -> AppliedState | None:
    """Load applied state from YAML. Returns None if missing or corrupt."""
    if not path.is_file():
        return None
    try:
        raw = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(raw, dict):
        return None
    try:
        return AppliedState(
            config_hash=raw["config_hash"],
            method=raw["method"],
            timestamp=raw["timestamp"],
        )
    except (KeyError, TypeError):
        return None


def save_state(path: Path, state: AppliedState) -> None:
    """Write applied state as YAML."""
    data = dataclasses.asdict(state)
    path.write_text(yaml.dump(data, default_flow_style=False), encoding="utf-8")


def needs_apply(current_hash: str, saved: AppliedState | None) -> bool:
    """Return True if hashes differ or no saved state exists."""
    if saved is None:
        return True
    return current_hash != saved.config_hash
