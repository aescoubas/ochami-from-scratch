from __future__ import annotations

from typing import Any

from typer.testing import CliRunner

import ochami.cli as cli_module
from ochami.cli import app

runner = CliRunner()


def test_cli_has_no_legacy_script_bridge() -> None:
    assert not hasattr(cli_module, "run_script")


def test_deploy_cli_uses_python_minikube_deployer(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run
            payload["interface"] = config.pxe_interface

    monkeypatch.setattr("ochami.cli.MinikubeDeployer", lambda: FakeDeployer())

    result = runner.invoke(
        app,
        [
            "deploy",
            "--method",
            "minikube",
            "--interface",
            "enp1s0",
            "--ip",
            "10.0.0.10",
            "--cidr",
            "20",
            "--vms",
            "3",
            "--auto-kill",
            "--dry-run",
        ],
    )

    assert result.exit_code == 0
    assert payload == {"method": "minikube", "dry_run": True, "interface": "enp1s0"}


def test_deploy_cli_uses_python_compose_deployer(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run
            payload["interface"] = config.pxe_interface
            payload["set_fs_protected_regular"] = config.set_fs_protected_regular

    monkeypatch.setattr("ochami.cli.ComposeDeployer", lambda: FakeDeployer())

    result = runner.invoke(
        app,
        [
            "deploy",
            "--method",
            "docker-compose",
            "--interface",
            "pxe0",
            "--dry-run",
        ],
    )

    assert result.exit_code == 0
    assert payload == {
        "method": "docker-compose",
        "dry_run": True,
        "interface": "pxe0",
        "set_fs_protected_regular": True,
    }


def test_deploy_cli_can_disable_default_fs_protected_regular_workaround(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["set_fs_protected_regular"] = config.set_fs_protected_regular
            payload["dry_run"] = dry_run

    monkeypatch.setattr("ochami.cli.ComposeDeployer", lambda: FakeDeployer())

    result = runner.invoke(
        app,
        [
            "deploy",
            "--method",
            "docker-compose",
            "--no-set-fs-protected-regular",
            "--dry-run",
        ],
    )

    assert result.exit_code == 0
    assert payload == {
        "method": "docker-compose",
        "set_fs_protected_regular": False,
        "dry_run": True,
    }


def test_deploy_cli_uses_python_quadlets_deployer(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run
            payload["interface"] = config.pxe_interface

    monkeypatch.setattr("ochami.cli.QuadletsDeployer", lambda: FakeDeployer())

    result = runner.invoke(
        app,
        [
            "deploy",
            "--method",
            "quadlets",
            "--interface",
            "pxe1",
            "--dry-run",
        ],
    )

    assert result.exit_code == 0
    assert payload == {"method": "quadlets", "dry_run": True, "interface": "pxe1"}


def test_deploy_cli_requires_method() -> None:
    result = runner.invoke(app, ["deploy", "--dry-run"])

    assert result.exit_code == 2
    assert "Missing option '--method'" in result.output


def test_teardown_cli_uses_python_minikube_teardown(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeTeardown:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run
            payload["remove_images"] = config.remove_images

    monkeypatch.setattr("ochami.cli.MinikubeTeardown", lambda: FakeTeardown())

    result = runner.invoke(
        app,
        [
            "teardown",
            "--method",
            "minikube",
            "--remove-images",
            "--vm-name",
            "node",
            "--yes",
            "--interface",
            "pxe0",
            "--ip",
            "172.16.0.2",
            "--cidr",
            "24",
        ],
    )

    assert result.exit_code == 0
    assert payload == {"method": "minikube", "dry_run": False, "remove_images": True}


def test_teardown_cli_uses_python_compose_teardown(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeTeardown:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run
            payload["remove_images"] = config.remove_images

    monkeypatch.setattr("ochami.cli.ComposeTeardown", lambda: FakeTeardown())

    result = runner.invoke(
        app,
        [
            "teardown",
            "--method",
            "docker-compose",
            "--remove-images",
            "--dry-run",
        ],
    )

    assert result.exit_code == 0
    assert payload == {"method": "docker-compose", "dry_run": True, "remove_images": True}


def test_teardown_cli_uses_python_quadlets_teardown(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeTeardown:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run
            payload["remove_images"] = config.remove_images

    monkeypatch.setattr("ochami.cli.QuadletsTeardown", lambda: FakeTeardown())

    result = runner.invoke(
        app,
        [
            "teardown",
            "--method",
            "quadlets",
            "--remove-images",
            "--dry-run",
        ],
    )

    assert result.exit_code == 0
    assert payload == {"method": "quadlets", "dry_run": True, "remove_images": True}


def test_teardown_cli_requires_method() -> None:
    result = runner.invoke(app, ["teardown", "--dry-run"])

    assert result.exit_code == 2
    assert "Missing option '--method'" in result.output


def test_deploy_cli_surfaces_validation_errors() -> None:
    result = runner.invoke(
        app,
        [
            "deploy",
            "--method",
            "minikube",
            "--ip",
            "999.1.2.3",
        ],
    )

    assert result.exit_code == 2
    assert "pxe_ip" in result.output
