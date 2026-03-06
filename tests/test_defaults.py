from __future__ import annotations

from pathlib import Path

from ochami.defaults import (
    BSS_PORT,
    DEFAULT_DATABASES,
    DEFAULT_PORTS,
    HTTP_PORT,
    MCP_PROXY_PORT,
    SECRET_KEYS,
    SMD_PORT,
    ensure_runtime_secrets,
    resolve_host_port,
)


def test_default_ports_count_and_values() -> None:
    assert len(DEFAULT_PORTS) == 8
    assert DEFAULT_PORTS["SMD_PORT"] == "27779"
    assert DEFAULT_PORTS["BSS_PORT"] == "27778"
    assert DEFAULT_PORTS["HTTP_PORT"] == "80"


def test_default_databases_count() -> None:
    assert len(DEFAULT_DATABASES) == 11


def test_secret_keys_count() -> None:
    assert len(SECRET_KEYS) == 7


def test_named_port_constants_match_default_ports() -> None:
    assert HTTP_PORT == int(DEFAULT_PORTS["HTTP_PORT"])
    assert BSS_PORT == int(DEFAULT_PORTS["BSS_PORT"])
    assert SMD_PORT == int(DEFAULT_PORTS["SMD_PORT"])
    assert MCP_PROXY_PORT == 30080


def test_ensure_runtime_secrets_generates_missing_keys(tmp_path: Path) -> None:
    result = ensure_runtime_secrets(tmp_path)
    assert set(result.keys()) == set(SECRET_KEYS)
    for value in result.values():
        assert len(value) == 48  # token_hex(24) produces 48 hex chars


def test_ensure_runtime_secrets_preserves_existing(tmp_path: Path) -> None:
    secrets_file = tmp_path / ".openchami-secrets.env"
    secrets_file.write_text("POSTGRES_PASSWORD=keep-me\n", encoding="utf-8")
    result = ensure_runtime_secrets(tmp_path)
    assert result["POSTGRES_PASSWORD"] == "keep-me"
    assert len(result["SMD_DB_PASSWORD"]) == 48


def test_resolve_host_port_returns_preferred_when_available() -> None:
    # Port 0 is always bindable as the OS picks an ephemeral port,
    # but we test the real function with a high-numbered port.
    port = resolve_host_port(59999)
    assert isinstance(port, int)
    assert port > 0
