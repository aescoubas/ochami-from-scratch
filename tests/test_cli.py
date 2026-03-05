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
    assert "method" in result.output.lower()


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
    assert "method" in result.output.lower()


def test_deploy_cli_with_config_file(monkeypatch: Any, tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: docker-compose\npxe_ip: 10.0.0.5\npxe_interface: eth1\n")

    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["pxe_ip"] = config.pxe_ip
            payload["interface"] = config.pxe_interface
            payload["dry_run"] = dry_run

    monkeypatch.setattr("ochami.cli.ComposeDeployer", lambda: FakeDeployer())

    result = runner.invoke(app, ["deploy", "--config", str(cfg_file), "--dry-run"])

    assert result.exit_code == 0
    assert payload == {
        "method": "docker-compose",
        "pxe_ip": "10.0.0.5",
        "interface": "eth1",
        "dry_run": True,
    }


def test_deploy_cli_cli_overrides_config_file(monkeypatch: Any, tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: docker-compose\npxe_ip: 10.0.0.5\n")

    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["pxe_ip"] = config.pxe_ip

    monkeypatch.setattr("ochami.cli.ComposeDeployer", lambda: FakeDeployer())

    result = runner.invoke(
        app,
        ["deploy", "--config", str(cfg_file), "--ip", "172.16.0.1", "--dry-run"],
    )

    assert result.exit_code == 0
    assert payload["pxe_ip"] == "172.16.0.1"  # CLI wins


def test_deploy_cli_method_from_config_file(monkeypatch: Any, tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: quadlets\n")

    payload: dict[str, Any] = {}

    class FakeDeployer:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value

    monkeypatch.setattr("ochami.cli.QuadletsDeployer", lambda: FakeDeployer())

    result = runner.invoke(app, ["deploy", "--config", str(cfg_file), "--dry-run"])

    assert result.exit_code == 0
    assert payload["method"] == "quadlets"


def test_teardown_cli_with_config_file(monkeypatch: Any, tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: minikube\npxe_ip: 10.0.0.5\npxe_interface: eth1\n")

    payload: dict[str, Any] = {}

    class FakeTeardown:
        def run(self, config: Any, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["pxe_ip"] = config.pxe_ip

    monkeypatch.setattr("ochami.cli.MinikubeTeardown", lambda: FakeTeardown())

    result = runner.invoke(
        app,
        ["teardown", "--config", str(cfg_file), "--dry-run"],
    )

    assert result.exit_code == 0
    assert payload == {"method": "minikube", "pxe_ip": "10.0.0.5"}


# ── apply command tests ────────────────────────────────────────────


def test_apply_cli_with_explicit_config(monkeypatch: Any, tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: docker-compose\npxe_ip: 10.0.0.5\n")

    payload: dict[str, Any] = {}

    class FakeDeployer:
        def apply(self, config: Any, *, state_path: Any, force: bool, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["pxe_ip"] = config.pxe_ip
            payload["force"] = force
            payload["dry_run"] = dry_run

    monkeypatch.setattr("ochami.cli.ComposeDeployer", lambda: FakeDeployer())

    result = runner.invoke(app, ["apply", "--config", str(cfg_file), "--dry-run"])

    assert result.exit_code == 0
    assert payload == {
        "method": "docker-compose",
        "pxe_ip": "10.0.0.5",
        "force": False,
        "dry_run": True,
    }


def test_apply_cli_with_method_flag(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def apply(self, config: Any, *, state_path: Any, force: bool, dry_run: bool) -> None:
            payload["method"] = config.method.value
            payload["dry_run"] = dry_run

    monkeypatch.setattr("ochami.cli.MinikubeDeployer", lambda: FakeDeployer())

    result = runner.invoke(app, ["apply", "--method", "minikube", "--dry-run"])

    assert result.exit_code == 0
    assert payload == {"method": "minikube", "dry_run": True}


def test_apply_cli_force_flag(monkeypatch: Any) -> None:
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def apply(self, config: Any, *, state_path: Any, force: bool, dry_run: bool) -> None:
            payload["force"] = force

    monkeypatch.setattr("ochami.cli.ComposeDeployer", lambda: FakeDeployer())

    result = runner.invoke(
        app, ["apply", "--method", "docker-compose", "--force", "--dry-run"]
    )

    assert result.exit_code == 0
    assert payload["force"] is True


def test_apply_cli_requires_method(monkeypatch: Any, tmp_path: Any) -> None:
    monkeypatch.chdir(tmp_path)  # no openchami.yaml here
    result = runner.invoke(app, ["apply", "--dry-run"])

    assert result.exit_code == 2
    assert "method" in result.output.lower()


def test_apply_cli_default_config_silent_when_missing(monkeypatch: Any) -> None:
    """apply without --config and no openchami.yaml should still work with --method."""
    payload: dict[str, Any] = {}

    class FakeDeployer:
        def apply(self, config: Any, *, state_path: Any, force: bool, dry_run: bool) -> None:
            payload["method"] = config.method.value

    monkeypatch.setattr("ochami.cli.QuadletsDeployer", lambda: FakeDeployer())

    result = runner.invoke(app, ["apply", "--method", "quadlets", "--dry-run"])

    assert result.exit_code == 0
    assert payload["method"] == "quadlets"


def test_apply_cli_explicit_missing_config_is_error() -> None:
    result = runner.invoke(
        app, ["apply", "--config", "/tmp/does-not-exist-openchami.yaml", "--dry-run"]
    )

    assert result.exit_code == 2


# ── check command tests ────────────────────────────────────────────


def test_check_valid_config(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: docker-compose\npxe_ip: 10.0.0.5\n")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 0
    assert "config ok" in result.output


def test_check_missing_config_file(tmp_path: Any) -> None:
    result = runner.invoke(app, ["check", "--config", str(tmp_path / "nope.yaml")])

    assert result.exit_code == 2
    assert "not found" in result.output


def test_check_invalid_ip(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: minikube\npxe_ip: 999.1.2.3\n")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 2
    assert "pxe_ip" in result.output


def test_check_invalid_cidr(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: minikube\npxe_cidr: 99\n")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 2
    assert "pxe_cidr" in result.output


def test_check_missing_method(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("pxe_ip: 10.0.0.5\n")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 2
    assert "method" in result.output.lower()


def test_check_empty_config(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 2
    assert "empty" in result.output.lower()


def test_check_unknown_keys(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: minikube\nbogus_key: value\n")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 2
    assert "bogus_key" in result.output


def test_check_magellan_without_targets(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: minikube\ndiscovery_method: magellan\n")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 2
    assert "magellan" in result.output.lower()


def test_check_dhcp_range_mismatch(tmp_path: Any) -> None:
    cfg_file = tmp_path / "openchami.yaml"
    cfg_file.write_text("method: minikube\ndhcp_start: 192.168.1.10\ndhcp_end: ''\n")

    result = runner.invoke(app, ["check", "--config", str(cfg_file)])

    assert result.exit_code == 2
    assert "dhcp" in result.output.lower()


# ── existing deploy validation test ───────────────────────────────


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
