from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

from ochami.config import DeployConfig, DeploymentMethod, TeardownConfig
from ochami.deploy.minikube import MinikubeDeployer
from ochami.teardown.minikube import MinikubeTeardown


class StubNetwork:
    def __init__(self) -> None:
        self.calls: list[tuple[str, Any]] = []

    def configure_for_minikube(self, config: DeployConfig, dry_run: bool) -> tuple[str, str]:
        self.calls.append(("configure", {"config": config, "dry_run": dry_run}))
        return config.pxe_ip, config.pxe_interface

    def cleanup_for_minikube(self, config: TeardownConfig, dry_run: bool) -> None:
        self.calls.append(("cleanup", {"config": config, "dry_run": dry_run}))


class StubRegistry:
    def __init__(self) -> None:
        self.bss_calls: list[dict[str, Any]] = []
        self.post_calls: list[dict[str, Any]] = []

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


def test_minikube_deployer_runs_expected_flow(tmp_path: Path) -> None:
    project_root = tmp_path
    _write(project_root / "ochami-helm/values-pxe.yaml", "externalIp: \"127.0.0.1\"\n")

    commands: list[list[str]] = []
    sa_checks = {"count": 0}

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        if cmd[:2] == ["minikube", "status"]:
            return 1
        if cmd[:6] == ["minikube", "kubectl", "--", "get", "sa", "default"]:
            sa_checks["count"] += 1
            return 0
        return 0

    output_calls: list[list[str]] = []

    def fake_output(cmd: list[str], **_: Any) -> str:
        output_calls.append(cmd)
        if cmd[:7] == ["minikube", "kubectl", "--", "get", "svc", "ochami-bss", "-n"]:
            return "10.96.1.20"
        return ""

    network = StubNetwork()
    registry = StubRegistry()
    prerequisites = StubPrerequisites()
    builder = StubBuilder()

    deployer = MinikubeDeployer(
        project_root=project_root,
        runner=fake_run,
        output_runner=fake_output,
        network=network,
        registry=registry,
        prerequisites=prerequisites,
        builder=builder,
        sleeper=lambda _seconds: None,
        macos=False,
        home_dir=project_root,
    )

    cfg = DeployConfig(
        method=DeploymentMethod.MINIKUBE,
        pxe_ip="192.168.100.2",
        pxe_interface="virbr-pxe",
        num_vms=2,
    )

    deployer.run(cfg, dry_run=False)

    assert network.calls and network.calls[0][0] == "configure"
    assert sa_checks["count"] == 1

    helm_cmd = next(cmd for cmd in commands if cmd[:3] == ["helm", "upgrade", "--install"])
    assert "ochami" in helm_cmd
    assert "-n" in helm_cmd
    assert "--wait" in helm_cmd

    assert any(cmd[:4] == ["minikube", "kubectl", "--", "create"] for cmd in commands)
    assert any(cmd[:4] == ["minikube", "kubectl", "--", "delete"] for cmd in commands)

    assert registry.bss_calls == [
        {
            "host": "10.96.1.20",
            "host_ip": "192.168.100.2",
            "extra_params": "ds=nocloud-net;s=http://192.168.100.2:80/cloud-init/",
            "dry_run": False,
        }
    ]
    assert registry.post_calls and registry.post_calls[0]["orchestrator"] == "minikube"
    assert prerequisites.calls == [{"set_fs_protected_regular": True, "dry_run": False}]
    assert builder.calls and builder.calls[0]["orchestrator"] == "minikube"

    mcp_path = project_root / ".openchami-mcp.env"
    assert mcp_path.is_file()
    assert "OPENCHAMI_BASE_URL=http://192.168.100.2:30080" in mcp_path.read_text(encoding="utf-8")

    assert any(cmd[:2] == ["minikube", "status"] for cmd in commands)
    assert ["sudo", "chmod", "-R", "a+rwX", str(project_root / ".minikube")] in commands
    assert ["sudo", "chmod", "-R", "a+rwX", str(project_root / ".kube")] in commands
    assert any(
        cmd[:5] == ["minikube", "kubectl", "--", "get", "svc"] and "ochami-bss" in cmd
        for cmd in output_calls
    )


def test_minikube_teardown_runs_expected_flow(tmp_path: Path) -> None:
    project_root = tmp_path
    artifacts_dir = project_root / "ochami-helm/http-server/artifacts"
    (artifacts_dir / "opensuse").mkdir(parents=True)
    (artifacts_dir / "ubuntu").mkdir(parents=True)
    _write(artifacts_dir / "vmlinuz-lts", "kernel\n")
    _write(artifacts_dir / "initramfs-lts", "initramfs\n")
    _write(artifacts_dir / "rootfs.squashfs", "rootfs\n")
    fs_state_path = project_root / "tmp/openchami-fs-protected-regular.state"
    _write(fs_state_path, "2\n")

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        if cmd[:3] == ["docker", "image", "inspect"]:
            return 0
        return 0

    def fake_output(cmd: list[str], **_: Any) -> str:
        if cmd[:4] == ["sudo", "virsh", "list", "--all"]:
            return "virtual-compute-node\nvirtual-compute-node-1\n"
        if cmd[:5] == ["minikube", "profile", "list", "-o", "json"]:
            return '{"valid":[{"Driver":"none"}]}'
        if cmd[:4] == ["sysctl", "-n", "fs.protected_regular"]:
            if fake_output.fs_read_count == 0:
                fake_output.fs_read_count += 1
                return "0"
            return "2"
        return ""
    fake_output.fs_read_count = 0  # type: ignore[attr-defined]

    network = StubNetwork()

    teardown = MinikubeTeardown(
        project_root=project_root,
        runner=fake_run,
        output_runner=fake_output,
        network=network,
        macos=False,
        fs_state_path=fs_state_path,
    )

    cfg = TeardownConfig(method=DeploymentMethod.MINIKUBE, remove_images=True, skip_confirm=True)
    teardown.run(cfg, dry_run=False)

    assert ["sudo", "virsh", "destroy", "virtual-compute-node"] in commands
    assert ["sudo", "virsh", "undefine", "--nvram", "virtual-compute-node"] in commands
    assert ["sudo", "virsh", "destroy", "virtual-compute-node-1"] in commands
    assert ["sudo", "virsh", "undefine", "--nvram", "virtual-compute-node-1"] in commands
    assert any(cmd[:3] == ["sudo", "-E", "minikube"] and cmd[-1] == "delete" for cmd in commands)
    assert any(cmd[:3] == ["docker", "image", "inspect"] for cmd in commands)
    assert any(cmd[:2] == ["docker", "rmi"] for cmd in commands)
    assert ["sudo", "rm", "-rf", "/opt/cni"] in commands
    assert network.calls and network.calls[0][0] == "cleanup"
    assert ["sudo", "sysctl", "-w", "fs.protected_regular=2"] in commands

    assert not (artifacts_dir / "opensuse").exists()
    assert not (artifacts_dir / "ubuntu").exists()
    assert not (artifacts_dir / "vmlinuz-lts").exists()
    assert not (artifacts_dir / "initramfs-lts").exists()
    assert not (artifacts_dir / "rootfs.squashfs").exists()
    assert not fs_state_path.exists()


def test_minikube_start_retries_after_fs_protected_regular_adjustment(tmp_path: Path) -> None:
    commands: list[list[str]] = []
    state = {"fs": "2", "start_attempts": 0}
    fs_state_path = tmp_path / "tmp/openchami-fs-protected-regular.state"

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        if cmd[:2] == ["minikube", "status"]:
            return 1
        if cmd[:4] == ["sudo", "-E", "minikube", "start"]:
            state["start_attempts"] += 1
            if state["start_attempts"] == 1:
                raise RuntimeError("command failed (37): sudo -E minikube start --driver=none --memory=4096 --cpus=2")
            return 0
        if cmd == ["sudo", "sysctl", "-w", "fs.protected_regular=0"]:
            state["fs"] = "0"
            return 0
        return 0

    def fake_output(cmd: list[str], **_: Any) -> str:
        if cmd[:4] == ["sysctl", "-n", "fs.protected_regular"]:
            return state["fs"]
        return ""

    deployer = MinikubeDeployer(
        project_root=tmp_path,
        runner=fake_run,
        output_runner=fake_output,
        sleeper=lambda _seconds: None,
        macos=False,
        home_dir=tmp_path / "home",
        fs_state_path=fs_state_path,
    )

    deployer._ensure_minikube_running(dry_run=False)

    assert state["start_attempts"] == 2
    assert ["sudo", "sysctl", "-w", "fs.protected_regular=0"] in commands
    assert ["sudo", "chmod", "-R", "a+rwX", str(tmp_path / "home/.minikube")] in commands
    assert ["sudo", "chmod", "-R", "a+rwX", str(tmp_path / "home/.kube")] in commands
    assert fs_state_path.read_text(encoding="utf-8").strip() == "2"


def test_minikube_start_raises_when_fs_workaround_not_applicable(tmp_path: Path) -> None:
    def fake_run(cmd: list[str], **_: Any) -> int:
        if cmd[:2] == ["minikube", "status"]:
            return 1
        if cmd[:4] == ["sudo", "-E", "minikube", "start"]:
            raise RuntimeError("command failed (51): sudo -E minikube start --driver=none --memory=4096 --cpus=2")
        return 0

    def fake_output(cmd: list[str], **_: Any) -> str:
        if cmd[:4] == ["sysctl", "-n", "fs.protected_regular"]:
            return "0"
        return ""

    deployer = MinikubeDeployer(
        project_root=tmp_path,
        runner=fake_run,
        output_runner=fake_output,
        sleeper=lambda _seconds: None,
        macos=False,
    )

    with pytest.raises(RuntimeError, match="command failed \\(51\\)"):
        deployer._ensure_minikube_running(dry_run=False)
