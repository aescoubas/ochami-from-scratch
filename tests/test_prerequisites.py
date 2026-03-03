from __future__ import annotations

from pathlib import Path
from typing import Any

from ochami.prerequisites import PrerequisitesInstaller


def test_debian_prerequisites_installer_runs_expected_commands(tmp_path: Path) -> None:
    commands: list[list[str]] = []
    sysctl_state = {"value": "1"}

    missing = {
        "conntrack",
        "socat",
        "go",
        "crictl",
        "cri-dockerd",
        "minikube",
        "helm",
    }

    def fake_command_exists(cmd: str) -> bool:
        return cmd not in missing

    def fake_run(cmd: list[str], **_kwargs: Any) -> int:
        commands.append(cmd)
        if cmd == ["python3", "-c", "import yaml"]:
            return 1
        if cmd == ["sudo", "systemctl", "is-active", "--quiet", "docker"]:
            return 1
        if cmd == ["sudo", "systemctl", "is-active", "--quiet", "cri-docker.socket"]:
            return 1
        if cmd == ["apt-cache", "show", "cri-tools"]:
            return 0
        if cmd == ["sudo", "sysctl", "-w", "fs.protected_regular=0"]:
            sysctl_state["value"] = "0"
        return 0

    def fake_output(cmd: list[str], **_kwargs: Any) -> str:
        if cmd == ["sysctl", "-n", "fs.protected_regular"]:
            return sysctl_state["value"]
        if cmd[:3] == ["curl", "-s", "https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest"]:
            return '{"assets":[{"browser_download_url":"https://example.test/cri-dockerd_0.3.20_amd64.deb"}]}'
        return ""

    installer = PrerequisitesInstaller(
        runner=fake_run,
        output_runner=fake_output,
        command_exists_fn=fake_command_exists,
        macos=False,
        fedora_release_path=tmp_path / "non-fedora",
        fs_state_path=tmp_path / "fs-protected.state",
    )
    installer.install(set_fs_protected_regular=True, dry_run=False)

    assert ["sudo", "apt-get", "update"] in commands
    assert ["sudo", "apt-get", "install", "-y", "conntrack", "socat"] in commands
    assert ["sudo", "apt-get", "install", "-y", "python3-yaml"] in commands
    assert ["sudo", "apt-get", "install", "-y", "golang-go"] in commands
    assert ["sudo", "apt-get", "install", "-y", "cri-tools"] in commands
    assert ["sudo", "systemctl", "start", "docker"] in commands
    assert ["curl", "-LO", "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"] in commands
    assert ["sudo", "sysctl", "-w", "fs.protected_regular=0"] in commands
    assert (tmp_path / "fs-protected.state").read_text(encoding="utf-8").strip() == "1"
