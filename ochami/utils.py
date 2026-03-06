from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
import hashlib
import ipaddress
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess


MAC_PATTERN = re.compile(r"^[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}$")
ENV_VAR_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def is_macos() -> bool:
    return platform.system() == "Darwin"


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def validate_ip(value: str, field_name: str = "ip") -> None:
    try:
        ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError as exc:
        raise ValueError(f"{field_name} must be a valid IPv4 address: {value!r}") from exc


def validate_mac(value: str, field_name: str = "mac") -> None:
    if not MAC_PATTERN.fullmatch(value):
        raise ValueError(f"{field_name} must be a valid MAC address: {value!r}")


def run(
    cmd: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    dry_run: bool = False,
    capture: bool = False,
) -> int:
    if dry_run:
        return 0

    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    extra: dict[str, object] = {}
    if capture:
        extra["capture_output"] = True
        extra["text"] = True

    completed = subprocess.run(
        list(cmd),
        cwd=str(cwd) if cwd else None,
        env=full_env,
        check=False,
        **extra,
    )
    if check and completed.returncode != 0:
        msg = f"command failed ({completed.returncode}): {' '.join(cmd)}"
        if capture and completed.stderr:
            msg += f"\n{completed.stderr.strip()}"
        raise RuntimeError(msg)
    return completed.returncode


def make_quiet_runner() -> Callable[..., int]:
    """Return a ``run`` wrapper that always captures subprocess output."""

    def quiet_run(
        cmd: Sequence[str],
        **kwargs: object,
    ) -> int:
        kwargs.setdefault("capture", True)
        return run(cmd, **kwargs)  # type: ignore[arg-type]

    return quiet_run


def run_output(
    cmd: Sequence[str],
    *,
    cwd: Path | None = None,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    dry_run: bool = False,
) -> str:
    if dry_run:
        return ""

    full_env = os.environ.copy()
    if env:
        full_env.update(env)

    completed = subprocess.run(
        list(cmd),
        cwd=str(cwd) if cwd else None,
        env=full_env,
        check=False,
        capture_output=True,
        text=True,
    )
    if check and completed.returncode != 0:
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(cmd)}")
    return completed.stdout.strip()


def parse_env_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}

    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def write_env_file(path: Path, values: Mapping[str, str]) -> None:
    lines = [f"{key}={value}" for key, value in values.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_file_if_changed(path: Path, content: str) -> bool:
    """Write content to path only if the file doesn't exist or content differs.

    Returns True if the file was written, False if skipped.
    """
    encoded = content.encode("utf-8")
    new_hash = hashlib.sha256(encoded).hexdigest()
    if path.is_file():
        existing_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        if existing_hash == new_hash:
            return False
    path.write_text(content, encoding="utf-8")
    return True


def substitute_env_vars(content: str, values: Mapping[str, str]) -> str:
    def replacer(match: re.Match[str]) -> str:
        key = match.group(1)
        return values.get(key, match.group(0))

    return ENV_VAR_PATTERN.sub(replacer, content)
