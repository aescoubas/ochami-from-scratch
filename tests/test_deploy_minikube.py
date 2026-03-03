from __future__ import annotations

from pathlib import Path
from typing import Any

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


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def test_minikube_deployer_runs_expected_flow(tmp_path: Path) -> None:
    project_root = tmp_path
    _write(project_root / "ochami-helm/values-pxe.yaml", "externalIp: \"127.0.0.1\"\n")
    _write(project_root / "scripts/common.sh", "#!/bin/bash\n")

    commands: list[list[str]] = []
    sa_checks = {"count": 0}

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
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

    deployer = MinikubeDeployer(
        project_root=project_root,
        runner=fake_run,
        output_runner=fake_output,
        network=network,
        registry=registry,
        sleeper=lambda _seconds: None,
        macos=False,
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

    mcp_path = project_root / ".openchami-mcp.env"
    assert mcp_path.is_file()
    assert "OPENCHAMI_BASE_URL=http://192.168.100.2:30080" in mcp_path.read_text(encoding="utf-8")

    assert any(cmd[:2] == ["minikube", "status"] for cmd in commands)
    assert any(
        cmd[:5] == ["minikube", "kubectl", "--", "get", "svc"] and "ochami-bss" in cmd
        for cmd in output_calls
    )


def test_minikube_teardown_runs_expected_flow(tmp_path: Path) -> None:
    project_root = tmp_path
    _write(project_root / "scripts/common.sh", "#!/bin/bash\n")

    commands: list[list[str]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        if cmd[:3] == ["docker", "image", "inspect"]:
            return 0
        return 0

    def fake_output(cmd: list[str], **_: Any) -> str:
        if cmd[:5] == ["minikube", "profile", "list", "-o", "json"]:
            return '{"valid":[{"Driver":"none"}]}'
        return ""

    network = StubNetwork()

    teardown = MinikubeTeardown(
        project_root=project_root,
        runner=fake_run,
        output_runner=fake_output,
        network=network,
        macos=False,
    )

    cfg = TeardownConfig(method=DeploymentMethod.MINIKUBE, remove_images=True, skip_confirm=True)
    teardown.run(cfg, dry_run=False)

    assert any("destroy_vms" in " ".join(cmd) for cmd in commands)
    assert any(cmd[:3] == ["sudo", "-E", "minikube"] and cmd[-1] == "delete" for cmd in commands)
    assert any(cmd[:3] == ["docker", "image", "inspect"] for cmd in commands)
    assert any(cmd[:2] == ["docker", "rmi"] for cmd in commands)
    assert ["sudo", "rm", "-rf", "/opt/cni"] in commands
    assert network.calls and network.calls[0][0] == "cleanup"

    assert any("cleanup_build_artifacts" in " ".join(cmd) for cmd in commands)
    assert any("restore_fs_protected_regular_if_managed" in " ".join(cmd) for cmd in commands)
