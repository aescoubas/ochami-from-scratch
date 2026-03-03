from __future__ import annotations

from typing import Any

from typer.testing import CliRunner

from ochami.cli import app

runner = CliRunner()


def test_deploy_cli_builds_bridge_call_for_non_compose(monkeypatch: Any) -> None:
    calls: list[dict[str, Any]] = []

    def fake_run(script_name: str, args: list[str], env: dict[str, str], dry_run: bool) -> int:
        calls.append(
            {
                "script_name": script_name,
                "args": args,
                "env": env,
                "dry_run": dry_run,
            }
        )
        return 0

    monkeypatch.setattr("ochami.cli.run_script", fake_run)

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
    assert len(calls) == 1
    assert calls[0]["script_name"] == "deploy.sh"
    assert calls[0]["dry_run"] is True
    assert calls[0]["args"][:2] == ["--method", "minikube"]
    assert "--interface" in calls[0]["args"]
    assert "enp1s0" in calls[0]["args"]
    assert "--ip" in calls[0]["args"]
    assert "10.0.0.10" in calls[0]["args"]
    assert "--cidr" in calls[0]["args"]
    assert "20" in calls[0]["args"]
    assert "--vms" in calls[0]["args"]
    assert "3" in calls[0]["args"]
    assert "--auto-kill" in calls[0]["args"]
    assert calls[0]["env"]["OPENCHAMI_METHOD"] == "minikube"
    assert calls[0]["env"]["OPENCHAMI_PXE_INTERFACE"] == "enp1s0"


def test_deploy_cli_uses_python_compose_deployer(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run
            payload["interface"] = config.pxe_interface

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
    assert payload == {"method": "docker-compose", "dry_run": True, "interface": "pxe0"}


def test_teardown_cli_builds_bridge_call(monkeypatch: Any) -> None:
    calls: list[dict[str, Any]] = []

    def fake_run(script_name: str, args: list[str], env: dict[str, str], dry_run: bool) -> int:
        calls.append(
            {
                "script_name": script_name,
                "args": args,
                "env": env,
                "dry_run": dry_run,
            }
        )
        return 0

    monkeypatch.setattr("ochami.cli.run_script", fake_run)

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
    assert len(calls) == 1
    assert calls[0]["script_name"] == "teardown.sh"
    assert calls[0]["args"][:2] == ["--method", "minikube"]
    assert "--remove-images" in calls[0]["args"]
    assert "--vm-name" in calls[0]["args"]
    assert "node" in calls[0]["args"]
    assert "--yes" in calls[0]["args"]
    assert "--interface" in calls[0]["args"]
    assert "pxe0" in calls[0]["args"]
    assert calls[0]["env"]["OPENCHAMI_METHOD"] == "minikube"


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
