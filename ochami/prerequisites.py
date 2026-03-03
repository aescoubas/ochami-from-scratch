from __future__ import annotations

import json
import re
from pathlib import Path

from ochami.utils import command_exists, is_macos, run, run_output


class PrerequisitesInstaller:
    def __init__(
        self,
        *,
        runner=run,
        output_runner=run_output,
        command_exists_fn=command_exists,
        macos: bool | None = None,
        fedora_release_path: Path = Path("/etc/fedora-release"),
        fs_state_path: Path = Path("/tmp/openchami-fs-protected-regular.state"),
    ) -> None:
        self._run = runner
        self._run_output = output_runner
        self._command_exists = command_exists_fn
        self._is_macos = is_macos() if macos is None else macos
        self._fedora_release_path = fedora_release_path
        self._fs_state_path = fs_state_path
        self._apt_updated = False

    def install(self, *, set_fs_protected_regular: bool, dry_run: bool) -> None:
        if self._is_macos:
            self._install_macos(dry_run=dry_run)
            return

        if self._fedora_release_path.is_file():
            self._install_fedora(set_fs_protected_regular=set_fs_protected_regular, dry_run=dry_run)
            return

        self._install_debian(set_fs_protected_regular=set_fs_protected_regular, dry_run=dry_run)

    def _install_debian(self, *, set_fs_protected_regular: bool, dry_run: bool) -> None:
        if (not self._command_exists("conntrack")) or (not self._command_exists("socat")):
            self._ensure_apt_update(dry_run=dry_run)
            self._run(["sudo", "apt-get", "install", "-y", "conntrack", "socat"], dry_run=dry_run)

        if self._run(["python3", "-c", "import yaml"], check=False, dry_run=dry_run) != 0:
            self._ensure_apt_update(dry_run=dry_run)
            self._run(["sudo", "apt-get", "install", "-y", "python3-yaml"], dry_run=dry_run)

        if not self._command_exists("go"):
            self._ensure_apt_update(dry_run=dry_run)
            self._run(["sudo", "apt-get", "install", "-y", "golang-go"], dry_run=dry_run)

        if not self._command_exists("crictl"):
            self._ensure_apt_update(dry_run=dry_run)
            if self._run(["apt-cache", "show", "cri-tools"], check=False, dry_run=dry_run) != 0:
                self._run(
                    ["sudo", "apt-get", "install", "-y", "apt-transport-https", "ca-certificates", "curl", "gpg"],
                    dry_run=dry_run,
                )
                self._run(["sudo", "mkdir", "-p", "-m", "755", "/etc/apt/keyrings"], dry_run=dry_run)
                self._run(
                    [
                        "bash",
                        "-lc",
                        (
                            "curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | "
                            "sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
                        ),
                    ],
                    dry_run=dry_run,
                )
                self._run(
                    [
                        "bash",
                        "-lc",
                        (
                            "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] "
                            "https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | "
                            "sudo tee /etc/apt/sources.list.d/kubernetes.list"
                        ),
                    ],
                    dry_run=dry_run,
                )
                self._run(["sudo", "apt-get", "update"], dry_run=dry_run)
                self._apt_updated = True
            self._run(["sudo", "apt-get", "install", "-y", "cri-tools"], dry_run=dry_run)

        if self._run(["sudo", "systemctl", "is-active", "--quiet", "docker"], check=False, dry_run=dry_run) != 0:
            self._run(["sudo", "systemctl", "start", "docker"], dry_run=dry_run)

        if not self._command_exists("cri-dockerd"):
            latest = self._latest_cri_dockerd_url(".deb")
            self._run(["wget", "-O", "/tmp/cri-dockerd.deb", latest], dry_run=dry_run)
            self._run(["sudo", "dpkg", "-i", "/tmp/cri-dockerd.deb"], dry_run=dry_run)
            self._run(["rm", "-f", "/tmp/cri-dockerd.deb"], dry_run=dry_run)
            self._run(["sudo", "systemctl", "enable", "--now", "cri-docker.socket"], dry_run=dry_run)
        elif self._run(["sudo", "systemctl", "is-active", "--quiet", "cri-docker.socket"], check=False, dry_run=dry_run) != 0:
            self._run(["sudo", "systemctl", "start", "cri-docker.socket"], dry_run=dry_run)

        cni_dir = Path("/opt/cni/bin")
        if (not cni_dir.is_dir()) or (not any(cni_dir.iterdir())):
            cni_url = "https://github.com/containernetworking/plugins/releases/download/v1.9.0/cni-plugins-linux-amd64-v1.9.0.tgz"
            self._run(["wget", "-O", "/tmp/cni-plugins.tgz", cni_url], dry_run=dry_run)
            self._run(["sudo", "mkdir", "-p", str(cni_dir)], dry_run=dry_run)
            self._run(["sudo", "tar", "-xzvf", "/tmp/cni-plugins.tgz", "-C", str(cni_dir)], dry_run=dry_run)
            self._run(["rm", "-f", "/tmp/cni-plugins.tgz"], dry_run=dry_run)

        if not self._command_exists("minikube"):
            self._run(["curl", "-LO", "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"], dry_run=dry_run)
            self._run(["sudo", "install", "minikube-linux-amd64", "/usr/local/bin/minikube"], dry_run=dry_run)
            self._run(["rm", "-f", "minikube-linux-amd64"], dry_run=dry_run)

        if not self._command_exists("helm"):
            self._run(
                ["bash", "-lc", "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"],
                dry_run=dry_run,
            )

        self._handle_fs_protected_regular(set_fs_protected_regular=set_fs_protected_regular, dry_run=dry_run)

    def _install_fedora(self, *, set_fs_protected_regular: bool, dry_run: bool) -> None:
        if (not self._command_exists("conntrack")) or (not self._command_exists("socat")):
            self._run(["sudo", "dnf", "install", "-y", "conntrack-tools", "socat"], dry_run=dry_run)

        if self._run(["python3", "-c", "import yaml"], check=False, dry_run=dry_run) != 0:
            self._run(["sudo", "dnf", "install", "-y", "python3-pyyaml"], dry_run=dry_run)

        if not self._command_exists("go"):
            self._run(["sudo", "dnf", "install", "-y", "golang"], dry_run=dry_run)

        if not self._command_exists("docker"):
            self._run(["sudo", "dnf", "-y", "install", "dnf-plugins-core"], dry_run=dry_run)
            self._run(
                ["sudo", "dnf", "config-manager", "addrepo", "--from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo"],
                dry_run=dry_run,
            )
            self._run(
                ["sudo", "dnf", "install", "-y", "docker-ce", "docker-ce-cli", "containerd.io", "docker-compose-plugin"],
                dry_run=dry_run,
            )
            self._run(["sudo", "systemctl", "enable", "--now", "docker"], dry_run=dry_run)

        if self._run(["sudo", "systemctl", "is-active", "--quiet", "docker"], check=False, dry_run=dry_run) != 0:
            self._run(["sudo", "systemctl", "start", "docker"], dry_run=dry_run)

        if not self._command_exists("podman"):
            self._run(["sudo", "dnf", "install", "-y", "podman"], dry_run=dry_run)

        if not self._command_exists("crictl"):
            repo_content = (
                "[kubernetes]\n"
                "name=Kubernetes\n"
                "baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/\n"
                "enabled=1\n"
                "gpgcheck=1\n"
                "gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key\n"
            )
            self._run(["bash", "-lc", f"cat <<'EOF' | sudo tee /etc/yum.repos.d/kubernetes.repo\n{repo_content}EOF"], dry_run=dry_run)
            self._run(["sudo", "dnf", "install", "-y", "cri-tools"], dry_run=dry_run)

        if not self._command_exists("cri-dockerd"):
            latest = self._latest_cri_dockerd_url(".rpm")
            self._run(["wget", "-O", "/tmp/cri-dockerd.rpm", latest], dry_run=dry_run)
            self._run(["sudo", "rpm", "-i", "/tmp/cri-dockerd.rpm"], dry_run=dry_run, check=False)
            self._run(["sudo", "dnf", "install", "-y", "/tmp/cri-dockerd.rpm"], dry_run=dry_run, check=False)
            self._run(["rm", "-f", "/tmp/cri-dockerd.rpm"], dry_run=dry_run)
            self._run(["sudo", "systemctl", "enable", "--now", "cri-docker.socket"], dry_run=dry_run)
        elif self._run(["sudo", "systemctl", "is-active", "--quiet", "cri-docker.socket"], check=False, dry_run=dry_run) != 0:
            self._run(["sudo", "systemctl", "start", "cri-docker.socket"], dry_run=dry_run)

        cni_dir = Path("/opt/cni/bin")
        if (not cni_dir.is_dir()) or (not any(cni_dir.iterdir())):
            cni_url = "https://github.com/containernetworking/plugins/releases/download/v1.9.0/cni-plugins-linux-amd64-v1.9.0.tgz"
            self._run(["wget", "-O", "/tmp/cni-plugins.tgz", cni_url], dry_run=dry_run)
            self._run(["sudo", "mkdir", "-p", str(cni_dir)], dry_run=dry_run)
            self._run(["sudo", "tar", "-xzvf", "/tmp/cni-plugins.tgz", "-C", str(cni_dir)], dry_run=dry_run)
            self._run(["rm", "-f", "/tmp/cni-plugins.tgz"], dry_run=dry_run)

        if not self._command_exists("minikube"):
            self._run(["curl", "-LO", "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"], dry_run=dry_run)
            self._run(["sudo", "install", "minikube-linux-amd64", "/usr/local/bin/minikube"], dry_run=dry_run)
            self._run(["rm", "-f", "minikube-linux-amd64"], dry_run=dry_run)

        if not self._command_exists("helm"):
            self._run(
                ["bash", "-lc", "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"],
                dry_run=dry_run,
            )

        if not self._command_exists("envsubst"):
            self._run(["sudo", "dnf", "install", "-y", "gettext"], dry_run=dry_run)

        self._handle_fs_protected_regular(set_fs_protected_regular=set_fs_protected_regular, dry_run=dry_run)

    def _install_macos(self, *, dry_run: bool) -> None:
        if not self._command_exists("brew"):
            raise RuntimeError("Homebrew is required on macOS")
        if not self._command_exists("docker"):
            raise RuntimeError("Docker Desktop is required on macOS")
        if self._run(["docker", "info"], check=False, dry_run=dry_run) != 0:
            raise RuntimeError("Docker is installed but not running")

        if not self._command_exists("envsubst"):
            self._run(["brew", "install", "gettext"], dry_run=dry_run)
        if not self._command_exists("python3"):
            self._run(["brew", "install", "python3"], dry_run=dry_run)
        if self._run(["python3", "-c", "import yaml"], check=False, dry_run=dry_run) != 0:
            self._run(["pip3", "install", "PyYAML"], dry_run=dry_run)
        if not self._command_exists("ggrep"):
            self._run(["brew", "install", "grep"], dry_run=dry_run)
        if not self._command_exists("minikube"):
            self._run(["brew", "install", "minikube"], dry_run=dry_run)
        if not self._command_exists("helm"):
            self._run(["brew", "install", "helm"], dry_run=dry_run)
        if not self._command_exists("mksquashfs"):
            self._run(["brew", "install", "squashfs"], dry_run=dry_run)

    def _ensure_apt_update(self, *, dry_run: bool) -> None:
        if self._apt_updated:
            return
        self._run(["sudo", "apt-get", "update"], dry_run=dry_run)
        self._apt_updated = True

    def _latest_cri_dockerd_url(self, suffix: str) -> str:
        output = self._run_output(
            ["curl", "-s", "https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest"],
            check=False,
        )
        if not output.strip():
            raise RuntimeError("failed to query cri-dockerd release metadata")

        urls: list[str] = []
        try:
            payload = json.loads(output)
            assets = payload.get("assets", [])
            if isinstance(assets, list):
                for asset in assets:
                    if not isinstance(asset, dict):
                        continue
                    url = asset.get("browser_download_url")
                    if isinstance(url, str):
                        urls.append(url)
        except json.JSONDecodeError:
            urls = re.findall(r"https://[^\"]+", output)

        for url in urls:
            if url.endswith(suffix):
                return url
        if suffix == ".rpm":
            for url in urls:
                if ".el9." in url and url.endswith(".rpm"):
                    return url
        raise RuntimeError(f"could not determine cri-dockerd download URL for {suffix}")

    def _handle_fs_protected_regular(self, *, set_fs_protected_regular: bool, dry_run: bool) -> None:
        current = self._run_output(["sysctl", "-n", "fs.protected_regular"], check=False, dry_run=dry_run).strip()
        if not set_fs_protected_regular:
            return
        if not current:
            return
        if current == "0":
            return
        self._run(["sudo", "sysctl", "-w", "fs.protected_regular=0"], dry_run=dry_run)
        verified = self._run_output(["sysctl", "-n", "fs.protected_regular"], check=False, dry_run=dry_run).strip()
        if verified == "0" and not dry_run:
            self._fs_state_path.write_text(current + "\n", encoding="utf-8")
