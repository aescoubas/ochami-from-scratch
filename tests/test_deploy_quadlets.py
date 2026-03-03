from __future__ import annotations

from pathlib import Path
import shutil
from typing import Any

from ochami.config import DeployConfig, DeploymentMethod, TeardownConfig
from ochami.deploy.quadlets import QuadletsDeployer
from ochami.teardown.quadlets import QuadletsTeardown
from ochami.templates import TemplateRenderer


class StubNetwork:
    def __init__(self) -> None:
        self.calls: list[tuple[str, Any]] = []

    def configure_for_quadlets(self, config: DeployConfig, dry_run: bool) -> str:
        self.calls.append(("configure", {"config": config, "dry_run": dry_run}))
        return config.pxe_ip

    def cleanup_for_quadlets(self, config: TeardownConfig, dry_run: bool) -> None:
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


class StubPrerequisites:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def install(self, *, set_fs_protected_regular: bool, dry_run: bool) -> None:
        self.calls.append(
            {
                "set_fs_protected_regular": set_fs_protected_regular,
                "dry_run": dry_run,
            }
        )


class StubBuilder:
    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []

    def build_images_if_needed(
        self,
        config: DeployConfig,
        *,
        orchestrator: str,
        container_tool: str,
        force_rebuild: bool,
        dry_run: bool,
    ) -> None:
        self.calls.append(
            {
                "config": config,
                "orchestrator": orchestrator,
                "container_tool": container_tool,
                "force_rebuild": force_rebuild,
                "dry_run": dry_run,
            }
        )


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def test_quadlets_deployer_generates_runtime_files_and_units(tmp_path: Path) -> None:
    project_root = tmp_path
    quadlets_dir = project_root / "ochami-quadlets"
    configs_src = quadlets_dir / "configs"
    units_src = quadlets_dir / "containers"
    configs_src.mkdir(parents=True)
    units_src.mkdir(parents=True)

    _write(configs_src / "kea-dhcp4.conf.template", '{"boot":"http://${HOST_IP}:${HTTP_PORT}/boot/v1/bootscript?mac=${mac}"}\n')
    _write(configs_src / "boot.ipxe.template", "set base-url http://${HOST_IP}:${HTTP_PORT}\n")
    _write(configs_src / "stork-server.env.template", "STORK_SERVER_PORT=${STORK_PORT}\n")
    _write(configs_src / "index.html", "<h1>ok</h1>\n")
    _write(configs_src / "kea-ctrl-agent.conf", "{}\n")
    _write(configs_src / "postgres-init-db.sh", "#!/bin/sh\necho init\n")
    _write(configs_src / "user-data", "#cloud-config\n")
    _write(configs_src / "meta-data", "instance-id: iid-local01\n")

    _write(
        units_src / "pcs.container",
        "Environment=POSTGRES_USER=${PCS_DB_USER}\nEnvironment=POSTGRES_PORT=${POSTGRES_PORT}\n",
    )
    _write(units_src / "openchami.target", "[Unit]\nDescription=OpenCHAMI\n")

    _write(project_root / "templates/nginx-default.conf.j2", "listen {{ http_port }};\n")

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        return 0

    network = StubNetwork()
    registry = StubRegistry()
    prerequisites = StubPrerequisites()
    builder = StubBuilder()
    install_dir = project_root / "etc/containers/systemd"
    config_dir = project_root / "etc/openchami"
    systemd_dir = project_root / "etc/systemd/system"

    deployer = QuadletsDeployer(
        project_root=project_root,
        runner=fake_run,
        renderer=TemplateRenderer(project_root / "templates"),
        network=network,
        registry=registry,
        prerequisites=prerequisites,
        builder=builder,
        secrets_provider=lambda: {
            "POSTGRES_PASSWORD": "pg-pass",
            "SMD_DB_PASSWORD": "smd-pass",
            "BSS_DB_PASSWORD": "bss-pass",
            "KEA_DB_PASSWORD": "kea-pass",
            "PCS_DB_PASSWORD": "pcs-pass",
            "STORK_DB_PASSWORD": "stork-pass",
            "HYDRA_DB_PASSWORD": "hydra-pass",
        },
        postgres_port_resolver=lambda _: 15432,
        quadlets_install_dir=install_dir,
        openchami_config_dir=config_dir,
        systemd_dir=systemd_dir,
        linux=True,
    )

    cfg = DeployConfig(
        method=DeploymentMethod.QUADLETS,
        pxe_ip="192.168.100.2",
        num_vms=2,
    )
    deployer.run(cfg, dry_run=False)

    env_file = config_dir / "openchami.env"
    assert env_file.is_file()
    env_content = env_file.read_text(encoding="utf-8")
    assert "HOST_IP=192.168.100.2" in env_content
    assert "POSTGRES_PORT=15432" in env_content
    assert "PCS_DB_PASSWORD=pcs-pass" in env_content
    assert "POSTGRES_MULTIPLE_DATABASES=" in env_content

    rendered_kea = (config_dir / "configs" / "kea-dhcp4.conf").read_text(encoding="utf-8")
    assert "bootscript?mac=${mac}" in rendered_kea
    assert (config_dir / "configs" / "nginx-default.conf").is_file()
    assert (config_dir / "configs" / "index.html").is_file()
    assert (config_dir / "configs" / "postgres-init-db.sh").is_file()

    pcs_unit = (install_dir / "pcs.container").read_text(encoding="utf-8")
    assert "Environment=POSTGRES_USER=pcs-user" in pcs_unit
    assert "Environment=POSTGRES_PORT=15432" in pcs_unit
    assert (systemd_dir / "openchami.target").is_file()
    assert (install_dir / "redfish-emulator-0.container").is_file()
    assert (install_dir / "redfish-emulator-1.container").is_file()

    assert ["sudo", "systemctl", "daemon-reload"] in commands
    assert ["sudo", "systemctl", "start", "openchami.target"] in commands
    assert network.calls
    assert registry.bss_calls and registry.post_calls
    assert prerequisites.calls == [{"set_fs_protected_regular": False, "dry_run": False}]
    assert builder.calls and builder.calls[0]["orchestrator"] == "quadlets"


def test_quadlets_teardown_removes_artifacts_and_calls_systemd(tmp_path: Path) -> None:
    project_root = tmp_path
    install_dir = project_root / "etc/containers/systemd"
    systemd_dir = project_root / "etc/systemd/system"
    config_dir = project_root / "etc/openchami"

    install_dir.mkdir(parents=True)
    systemd_dir.mkdir(parents=True)
    config_dir.mkdir(parents=True)
    _write(install_dir / "a.container", "[Unit]\n")
    _write(systemd_dir / "openchami.target", "[Unit]\n")
    _write(config_dir / "openchami.env", "HOST_IP=1.2.3.4\n")
    artifacts_dir = project_root / "ochami-helm/http-server/artifacts"
    (artifacts_dir / "opensuse").mkdir(parents=True)
    (artifacts_dir / "ubuntu").mkdir(parents=True)
    for name in ("vmlinuz-lts", "initramfs-lts", "rootfs.squashfs"):
        (artifacts_dir / name).write_text("x\n", encoding="utf-8")
    fs_state_path = project_root / "tmp/openchami-fs-protected-regular.state"
    fs_state_path.parent.mkdir(parents=True, exist_ok=True)
    fs_state_path.write_text("2\n", encoding="utf-8")

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        if cmd[:4] == ["sudo", "podman", "volume", "exists"]:
            return 0
        if cmd[:4] == ["sudo", "podman", "image", "inspect"]:
            return 0
        return 0

    def fake_output(cmd: list[str], **_: Any) -> str:
        if cmd[:4] == ["sudo", "virsh", "list", "--all"]:
            return "virtual-compute-node\n"
        if cmd[:4] == ["sysctl", "-n", "fs.protected_regular"]:
            if fake_output.fs_read_count == 0:
                fake_output.fs_read_count += 1
                return "0"
            return "2"
        return ""
    fake_output.fs_read_count = 0  # type: ignore[attr-defined]

    network = StubNetwork()
    teardown = QuadletsTeardown(
        project_root=project_root,
        runner=fake_run,
        output_runner=fake_output,
        network=network,
        quadlets_install_dir=install_dir,
        openchami_config_dir=config_dir,
        systemd_dir=systemd_dir,
        fs_state_path=fs_state_path,
        linux=True,
    )
    cfg = TeardownConfig(method=DeploymentMethod.QUADLETS, remove_images=True, skip_confirm=True)

    teardown.run(cfg, dry_run=False)

    assert ["sudo", "virsh", "destroy", "virtual-compute-node"] in commands
    assert ["sudo", "virsh", "undefine", "--nvram", "virtual-compute-node"] in commands
    assert ["sudo", "systemctl", "stop", "openchami.target"] in commands
    assert ["sudo", "systemctl", "stop", "a.service"] in commands
    assert ["sudo", "systemctl", "daemon-reload"] in commands
    assert ["sudo", "podman", "volume", "rm", "systemd-postgres-data"] in commands
    assert ["sudo", "podman", "volume", "rm", "systemd-kea-sockets"] in commands
    assert any(cmd[:4] == ["sudo", "podman", "image", "inspect"] for cmd in commands)
    assert any(cmd[:3] == ["sudo", "podman", "rmi"] for cmd in commands)
    assert ["sudo", "sysctl", "-w", "fs.protected_regular=2"] in commands
    assert network.calls and network.calls[0][0] == "cleanup"

    assert not (install_dir / "a.container").exists()
    assert not (systemd_dir / "openchami.target").exists()
    assert not config_dir.exists()
    assert not (artifacts_dir / "opensuse").exists()
    assert not (artifacts_dir / "ubuntu").exists()
    assert not (artifacts_dir / "vmlinuz-lts").exists()
    assert not (artifacts_dir / "initramfs-lts").exists()
    assert not (artifacts_dir / "rootfs.squashfs").exists()
    assert not fs_state_path.exists()


def test_quadlets_deployer_uses_sudo_fallback_on_permission_error(tmp_path: Path, monkeypatch: Any) -> None:
    project_root = tmp_path
    quadlets_dir = project_root / "ochami-quadlets"
    configs_src = quadlets_dir / "configs"
    units_src = quadlets_dir / "containers"
    configs_src.mkdir(parents=True)
    units_src.mkdir(parents=True)

    _write(configs_src / "postgres-init-db.sh", "#!/bin/sh\necho init\n")
    _write(units_src / "pcs.container", "Environment=POSTGRES_USER=${PCS_DB_USER}\n")
    _write(units_src / "openchami.target", "[Unit]\nDescription=OpenCHAMI\n")
    _write(project_root / "templates/nginx-default.conf.j2", "listen {{ http_port }};\n")

    blocked_root = project_root / "blocked"
    install_dir = blocked_root / "etc/containers/systemd"
    config_dir = blocked_root / "etc/openchami"
    systemd_dir = blocked_root / "etc/systemd/system"

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        return 0

    original_mkdir = Path.mkdir

    def deny_mkdir(self: Path, *args: Any, **kwargs: Any) -> None:
        if str(self).startswith(str(blocked_root)):
            raise PermissionError("permission denied for test")
        original_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", deny_mkdir)

    deployer = QuadletsDeployer(
        project_root=project_root,
        runner=fake_run,
        renderer=TemplateRenderer(project_root / "templates"),
        network=StubNetwork(),
        registry=StubRegistry(),
        prerequisites=StubPrerequisites(),
        builder=StubBuilder(),
        secrets_provider=lambda: {
            "POSTGRES_PASSWORD": "pg-pass",
            "SMD_DB_PASSWORD": "smd-pass",
            "BSS_DB_PASSWORD": "bss-pass",
            "KEA_DB_PASSWORD": "kea-pass",
            "PCS_DB_PASSWORD": "pcs-pass",
            "STORK_DB_PASSWORD": "stork-pass",
            "HYDRA_DB_PASSWORD": "hydra-pass",
        },
        quadlets_install_dir=install_dir,
        openchami_config_dir=config_dir,
        systemd_dir=systemd_dir,
        linux=True,
    )

    cfg = DeployConfig(
        method=DeploymentMethod.QUADLETS,
        pxe_ip="192.168.100.2",
        num_vms=0,
    )
    deployer.run(cfg, dry_run=False)

    assert ["sudo", "mkdir", "-p", str(config_dir / "configs")] in commands
    assert any(
        cmd[:5] == ["sudo", "install", "-D", "-m", "0644"] and cmd[-1] == str(config_dir / "openchami.env")
        for cmd in commands
    )
    assert any(
        cmd[:5] == ["sudo", "install", "-D", "-m", "0644"] and cmd[-1] == str(systemd_dir / "openchami.target")
        for cmd in commands
    )


def test_quadlets_teardown_uses_sudo_fallback_on_permission_error(tmp_path: Path, monkeypatch: Any) -> None:
    project_root = tmp_path
    protected_root = project_root / "protected"
    install_dir = protected_root / "etc/containers/systemd"
    systemd_dir = protected_root / "etc/systemd/system"
    config_dir = protected_root / "etc/openchami"

    install_dir.mkdir(parents=True)
    systemd_dir.mkdir(parents=True)
    config_dir.mkdir(parents=True)
    _write(install_dir / "a.container", "[Unit]\n")
    _write(systemd_dir / "openchami.target", "[Unit]\n")
    _write(config_dir / "openchami.env", "HOST_IP=1.2.3.4\n")

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        return 0

    def fake_output(cmd: list[str], **_: Any) -> str:
        return ""

    original_unlink = Path.unlink
    original_rmtree = shutil.rmtree

    def deny_unlink(self: Path, *args: Any, **kwargs: Any) -> None:
        if str(self).startswith(str(protected_root)):
            raise PermissionError("permission denied for test")
        original_unlink(self, *args, **kwargs)

    def deny_rmtree(path: Any, *args: Any, **kwargs: Any) -> None:
        if str(path).startswith(str(protected_root)):
            raise PermissionError("permission denied for test")
        original_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(Path, "unlink", deny_unlink)
    monkeypatch.setattr(shutil, "rmtree", deny_rmtree)

    teardown = QuadletsTeardown(
        project_root=project_root,
        runner=fake_run,
        output_runner=fake_output,
        network=StubNetwork(),
        quadlets_install_dir=install_dir,
        openchami_config_dir=config_dir,
        systemd_dir=systemd_dir,
        linux=True,
    )
    cfg = TeardownConfig(method=DeploymentMethod.QUADLETS, remove_images=False, skip_confirm=True)
    teardown.run(cfg, dry_run=False)

    assert ["sudo", "systemctl", "stop", "a.service"] in commands
    assert ["sudo", "rm", "-f", str(install_dir / "a.container")] in commands
    assert ["sudo", "rm", "-f", str(systemd_dir / "openchami.target")] in commands
    assert ["sudo", "rm", "-rf", str(config_dir)] in commands


def test_quadlet_templates_use_runtime_postgres_port() -> None:
    project_root = Path(__file__).resolve().parents[1]
    containers_dir = project_root / "ochami-quadlets" / "containers"

    pcs_init = (containers_dir / "pcs-init.container").read_text(encoding="utf-8")
    pcs = (containers_dir / "pcs.container").read_text(encoding="utf-8")
    postgres = (containers_dir / "postgres.container").read_text(encoding="utf-8")

    assert "Environment=POSTGRES_PORT=5432" not in pcs_init
    assert "Environment=POSTGRES_PORT=5432" not in pcs
    assert "Environment=POSTGRES_PORT=${POSTGRES_PORT}" in pcs_init
    assert "Environment=POSTGRES_PORT=${POSTGRES_PORT}" in pcs
    assert "Exec=postgres -p ${POSTGRES_PORT}" in postgres
