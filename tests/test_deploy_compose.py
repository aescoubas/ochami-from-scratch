from __future__ import annotations

from pathlib import Path
from typing import Any

from ochami.config import DeployConfig, DeploymentMethod, TeardownConfig
from ochami.deploy.compose import ComposeDeployer
from ochami.teardown.compose import ComposeTeardown
from ochami.templates import TemplateRenderer


class StubNetwork:
    def __init__(self) -> None:
        self.calls: list[tuple[str, Any]] = []

    def configure_for_compose(self, config: DeployConfig, dry_run: bool) -> str:
        self.calls.append(("configure", {"config": config, "dry_run": dry_run}))
        return config.pxe_ip

    def cleanup_for_compose(self, config: TeardownConfig, dry_run: bool) -> None:
        self.calls.append(("cleanup", {"config": config, "dry_run": dry_run}))


class StubRegistry:
    def __init__(self) -> None:
        self.waited: list[tuple[str, str]] = []
        self.bss_calls: list[dict[str, Any]] = []
        self.post_calls: list[dict[str, Any]] = []

    def wait_for_services(self, checks: list[tuple[str, str]], dry_run: bool) -> None:
        if dry_run:
            return
        self.waited.extend(checks)

    def register_bss_defaults(self, host: str, host_ip: str, extra_params: str, dry_run: bool) -> None:
        self.bss_calls.append(
            {
                "host": host,
                "host_ip": host_ip,
                "extra_params": extra_params,
                "dry_run": dry_run,
            }
        )

    def run_post_deploy_flow(self, config: DeployConfig, host_ip: str, orchestrator: str, dry_run: bool) -> None:
        self.post_calls.append(
            {
                "config": config,
                "host_ip": host_ip,
                "orchestrator": orchestrator,
                "dry_run": dry_run,
            }
        )


def _write_template(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def test_compose_deployer_generates_env_and_configs(tmp_path: Path) -> None:
    project_root = tmp_path
    compose_dir = project_root / "ochami-docker-compose"
    configs_dir = compose_dir / "configs"
    compose_dir.mkdir(parents=True)
    configs_dir.mkdir(parents=True)
    (compose_dir / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")

    _write_template(project_root / "templates/compose/kea-dhcp4.conf.j2", '{"interfaces":["{{ pxe_interface }}"],"boot":"http://{{ host_ip }}:{{ http_port }}/boot/v1/bootscript?mac=${mac}"}\n')
    _write_template(project_root / "templates/compose/boot.ipxe.j2", "set base-url http://{{ host_ip }}:{{ http_port }}\n")
    _write_template(project_root / "templates/compose/stork-server.env.j2", "STORK_SERVER_PORT={{ stork_port }}\n")
    _write_template(project_root / "templates/nginx-default.conf.j2", "listen {{ http_port }};\n")

    static_ctrl_agent = configs_dir / "kea-ctrl-agent.conf"
    static_ctrl_agent.write_text("{}", encoding="utf-8")

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        return 0

    network = StubNetwork()
    registry = StubRegistry()

    deployer = ComposeDeployer(
        project_root=project_root,
        runner=fake_run,
        renderer=TemplateRenderer(project_root / "templates"),
        network=network,
        registry=registry,
        secrets_provider=lambda: {
            "POSTGRES_PASSWORD": "pg-pass",
            "SMD_DB_PASSWORD": "smd-pass",
            "BSS_DB_PASSWORD": "bss-pass",
            "KEA_DB_PASSWORD": "kea-pass",
            "PCS_DB_PASSWORD": "pcs-pass",
            "STORK_DB_PASSWORD": "stork-pass",
            "HYDRA_DB_PASSWORD": "hydra-pass",
        },
    )

    cfg = DeployConfig(
        method=DeploymentMethod.DOCKER_COMPOSE,
        num_vms=2,
        pxe_interface="virbr-pxe",
        pxe_ip="192.168.100.2",
    )

    deployer.run(cfg, dry_run=False)

    env_path = compose_dir / ".env"
    assert env_path.is_file()
    env_content = env_path.read_text(encoding="utf-8")
    assert "HOST_IP=192.168.100.2" in env_content
    assert "NUM_VMS=2" in env_content
    assert "POSTGRES_PASSWORD=pg-pass" in env_content

    assert (configs_dir / "kea-dhcp4.conf").is_file()
    assert (configs_dir / "boot.ipxe").is_file()
    assert (configs_dir / "stork-server.env").is_file()
    assert (configs_dir / "nginx-default.conf").is_file()

    compose_cmd = next(cmd for cmd in commands if cmd[:3] == ["docker", "compose", "-p"])
    assert "--env-file" in compose_cmd
    assert "--profile" in compose_cmd
    assert "emulator" in compose_cmd
    assert compose_cmd[-3:] == ["up", "-d", "--wait"]
    assert network.calls
    assert registry.bss_calls
    assert registry.post_calls


def test_compose_teardown_issues_expected_commands(tmp_path: Path) -> None:
    project_root = tmp_path
    compose_dir = project_root / "ochami-docker-compose"
    configs_dir = compose_dir / "configs"
    compose_dir.mkdir(parents=True)
    configs_dir.mkdir(parents=True)
    (compose_dir / "docker-compose.yml").write_text("services: {}\n", encoding="utf-8")
    (compose_dir / ".env").write_text("HOST_IP=127.0.0.1\n", encoding="utf-8")
    for name in ("kea-dhcp4.conf", "nginx-default.conf", "boot.ipxe", "stork-server.env"):
        (configs_dir / name).write_text("x\n", encoding="utf-8")

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        return 0

    network = StubNetwork()
    teardown = ComposeTeardown(project_root=project_root, runner=fake_run, network=network)
    cfg = TeardownConfig(method=DeploymentMethod.DOCKER_COMPOSE, remove_images=True, skip_confirm=True)

    teardown.run(cfg, dry_run=False)

    down_cmd = next(cmd for cmd in commands if cmd[:3] == ["docker", "compose", "-p"])
    assert down_cmd[-3:] == ["down", "-v", "--remove-orphans"]
    assert any(cmd[:3] == ["docker", "image", "inspect"] for cmd in commands)
    assert any(cmd[:2] == ["docker", "rmi"] for cmd in commands)
    assert network.calls and network.calls[0][0] == "cleanup"
    assert not (compose_dir / ".env").exists()
    assert not (configs_dir / "kea-dhcp4.conf").exists()
