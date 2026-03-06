"""Shared constants and helpers used across all deployment methods.

This module centralises port numbers, database names, secret-key
definitions, and small utility functions that were previously scattered
across ``ochami.deploy.compose``, ``ochami.deploy.minikube``, and
``ochami.registry``.
"""

from __future__ import annotations

import secrets
import socket
from pathlib import Path

from ochami.utils import parse_env_file, write_env_file

DEFAULT_PORTS: dict[str, str] = {
    "SMD_PORT": "27779",
    "BSS_PORT": "27778",
    "POSTGRES_PORT": "5432",
    "HTTP_PORT": "80",
    "CLOUD_INIT_PORT": "27777",
    "PCS_PORT": "28007",
    "STORK_PORT": "28010",
    "STORK_AGENT_PORT": "28011",
}

DEFAULT_DATABASES: dict[str, str] = {
    "POSTGRES_USER": "ochami",
    "SMD_DB_NAME": "hmsds",
    "SMD_DB_USER": "smd-user",
    "BSS_DB_NAME": "bssdb",
    "BSS_DB_USER": "bss-user",
    "KEA_DB_NAME": "kea",
    "KEA_DB_USER": "kea-user",
    "PCS_DB_NAME": "pcsdb",
    "PCS_DB_USER": "pcs-user",
    "STORK_DB_NAME": "stork",
    "STORK_DB_USER": "stork-user",
}

SECRET_KEYS: list[str] = [
    "POSTGRES_PASSWORD",
    "SMD_DB_PASSWORD",
    "BSS_DB_PASSWORD",
    "KEA_DB_PASSWORD",
    "PCS_DB_PASSWORD",
    "STORK_DB_PASSWORD",
    "HYDRA_DB_PASSWORD",
]

# Named integer port constants — single source of truth.
HTTP_PORT: int = int(DEFAULT_PORTS["HTTP_PORT"])
BSS_PORT: int = int(DEFAULT_PORTS["BSS_PORT"])
SMD_PORT: int = int(DEFAULT_PORTS["SMD_PORT"])
MCP_PROXY_PORT: int = 30080  # minikube NodePort


def ensure_runtime_secrets(project_root: Path) -> dict[str, str]:
    """Generate or load runtime secrets from ``.openchami-secrets.env``."""
    path = project_root / ".openchami-secrets.env"
    values = parse_env_file(path)

    for key in SECRET_KEYS:
        env_override = values.get(key, "")
        if key in values and env_override:
            continue
        values[key] = values.get(key) or secrets.token_hex(24)

    ordered = {key: values[key] for key in SECRET_KEYS}
    write_env_file(path, ordered)
    path.chmod(0o600)
    return ordered


def resolve_host_port(preferred_port: int) -> int:
    """Return *preferred_port* if available, otherwise scan a fallback range."""
    if _is_host_port_available(preferred_port):
        return preferred_port

    for candidate in range(15432, 16433):
        if _is_host_port_available(candidate):
            return candidate

    raise RuntimeError("could not find an available host port for PostgreSQL")


def _is_host_port_available(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", port))
        except OSError:
            return False
    return True
