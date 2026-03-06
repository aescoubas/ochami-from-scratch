from __future__ import annotations

import io
from unittest.mock import patch

from ochami.console import Console, NullConsole


def _capture_stderr(func):
    """Run *func* while capturing stderr and return the captured text."""
    buf = io.StringIO()
    with patch("sys.stderr", buf):
        func()
    return buf.getvalue()


def test_phase_prints_ok_on_success() -> None:
    console = Console()
    output = _capture_stderr(lambda: _run_phase(console, "Installing..."))
    assert "Installing..." in output
    assert "ok" in output


def test_phase_prints_failed_on_exception() -> None:
    console = Console()

    def action():
        try:
            with console.phase("Building..."):
                raise RuntimeError("boom")
        except RuntimeError:
            pass

    output = _capture_stderr(action)
    assert "Building..." in output
    assert "FAILED" in output


def test_phase_set_detail_appears_in_output() -> None:
    console = Console()

    def action():
        with console.phase("Configuring network...") as ctx:
            ctx.set_detail("192.168.100.2")

    output = _capture_stderr(action)
    assert "ok (192.168.100.2)" in output


def test_phase_dry_run_shows_dry_run() -> None:
    console = Console(dry_run=True)
    output = _capture_stderr(lambda: _run_phase(console, "Starting..."))
    assert "dry-run" in output
    assert "ok" not in output.replace("dry-run", "")


def test_header_formatting() -> None:
    console = Console()
    output = _capture_stderr(lambda: console.header("Deploying OpenCHAMI (docker-compose)"))
    assert "Deploying OpenCHAMI (docker-compose)" in output


def test_footer_formatting() -> None:
    console = Console()

    def action():
        console.footer("Deploy complete.", details={"MCP": "http://192.168.100.2:80"})

    output = _capture_stderr(action)
    assert "Deploy complete." in output
    assert "MCP: http://192.168.100.2:80" in output


def test_footer_without_details() -> None:
    console = Console()
    output = _capture_stderr(lambda: console.footer("Already up to date."))
    assert "Already up to date." in output


def test_null_console_produces_no_output() -> None:
    console = NullConsole()

    def action():
        console.header("header")
        with console.phase("phase") as ctx:
            ctx.set_detail("detail")
        console.footer("footer", details={"k": "v"})

    output = _capture_stderr(action)
    assert output == ""


def test_phase_exception_propagates() -> None:
    console = Console()
    raised = False
    try:
        buf = io.StringIO()
        with patch("sys.stderr", buf):
            with console.phase("Failing..."):
                raise ValueError("test error")
    except ValueError:
        raised = True
    assert raised


def _run_phase(console: Console, label: str) -> None:
    with console.phase(label):
        pass
