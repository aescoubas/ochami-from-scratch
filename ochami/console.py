"""Structured progress output for deploy commands.

Prints phased status lines to stderr so stdout remains clean for
programmatic capture.  ``NullConsole`` is the silent default used by
tests and when no console is injected.
"""

from __future__ import annotations

import sys
from contextlib import contextmanager
from typing import Iterator


_LABEL_WIDTH = 38  # pad phase labels to this column


class _PhaseContext:
    """Mutable context passed into a ``phase()`` block."""

    def __init__(self) -> None:
        self.detail: str = ""

    def set_detail(self, text: str) -> None:
        self.detail = text


class Console:
    """Minimal progress reporter that writes to *stderr*."""

    def __init__(self, *, verbose: bool = False, dry_run: bool = False) -> None:
        self.verbose = verbose
        self.dry_run = dry_run

    def header(self, text: str) -> None:
        sys.stderr.write(f"\n{text}\n\n")
        sys.stderr.flush()

    @contextmanager
    def phase(self, label: str) -> Iterator[_PhaseContext]:
        ctx = _PhaseContext()
        padded = f"  {label}".ljust(_LABEL_WIDTH)
        try:
            yield ctx
        except Exception:
            sys.stderr.write(f"{padded}FAILED\n")
            sys.stderr.flush()
            raise
        else:
            if self.dry_run:
                tag = "dry-run"
            else:
                tag = "ok"
            suffix = f" ({ctx.detail})" if ctx.detail else ""
            sys.stderr.write(f"{padded}{tag}{suffix}\n")
            sys.stderr.flush()

    def footer(self, text: str, *, details: dict[str, str] | None = None) -> None:
        sys.stderr.write(f"\n{text}\n")
        if details:
            for key, value in details.items():
                sys.stderr.write(f"  {key}: {value}\n")
        sys.stderr.flush()


class NullConsole(Console):
    """Silent console that produces no output — used by tests."""

    def __init__(self) -> None:
        super().__init__(verbose=False, dry_run=False)

    def header(self, text: str) -> None:
        pass

    @contextmanager
    def phase(self, label: str) -> Iterator[_PhaseContext]:
        yield _PhaseContext()

    def footer(self, text: str, *, details: dict[str, str] | None = None) -> None:
        pass
