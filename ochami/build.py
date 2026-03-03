from __future__ import annotations

from dataclasses import dataclass
import fnmatch
import os
from pathlib import Path
import shlex
import shutil
import tarfile
import tempfile
import time
from typing import Callable

from ochami.config import DeployConfig
from ochami.utils import command_exists, run, run_output


IMAGE_HTTP = "localhost/http-server:latest"
IMAGE_TFTP = "localhost/tftp:latest"
IMAGE_EMULATOR = "localhost/redfish-emulator:latest"
IMAGE_STORK_AGENT = "localhost/stork-agent:latest"
IMAGE_KEA_SIDECAR = "localhost/kea-sidecar:latest"
IMAGE_SMD = "localhost/smd:local-smd"
IMAGE_BSS = "localhost/bss:local-bss"
IMAGE_PCS = "localhost/pcs:local-pcs"

DEFAULT_BASE_IMAGES = {
    "BASE_IMAGE_HTTP_SERVER": "nginx:1.27.5-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10",
    "BASE_IMAGE_REDFISH_EMULATOR": "python:3.9.21-slim-bookworm@sha256:40007fe18a72a2e7166be350d52dab86b9fe18f2de08e6a38e26422fb247e81e",
    "BASE_IMAGE_TFTP": "alpine:3.18.12@sha256:de0eb0b3f2a47ba1eb89389859a9bd88b28e82f5826b6969ad604979713c2d4f",
    "BASE_IMAGE_STORK_AGENT": "jonasal/kea-dhcp4:3.1.4@sha256:061b5cc8d6f67b507dc7647a8c21ee0603ed0f572bfce616dea83419f8d37295",
    "BASE_IMAGE_KEA_SIDECAR": "python:3.9.21-slim-bookworm@sha256:40007fe18a72a2e7166be350d52dab86b9fe18f2de08e6a38e26422fb247e81e",
    "BASE_IMAGE_SLES_BUILDER": "opensuse/leap:15.6@sha256:ba2e33cef0c84c15fe5bc91c3a9fa8f9257e8c301040c4226f32ebb6ad9a0b39",
}

DEFAULT_REPO_URIS = {
    "smd": "https://github.com/aescoubas/ochami-smd.git",
    "bss": "https://github.com/aescoubas/ochami-bss.git",
    "pcs": "https://github.com/OpenCHAMI/power-control.git",
}


def sanitize_tag(git_ref: str) -> str:
    return git_ref.replace("/", "-")


@dataclass(slots=True)
class RetryPolicy:
    attempts: int = 3
    delay_seconds: int = 5

    def normalized(self) -> "RetryPolicy":
        attempts = self.attempts if self.attempts > 0 else 1
        delay = self.delay_seconds if self.delay_seconds >= 0 else 0
        return RetryPolicy(attempts=attempts, delay_seconds=delay)


class BuildManager:
    def __init__(
        self,
        project_root: Path,
        *,
        runner=run,
        output_runner=run_output,
        sleeper: Callable[[float], None] = time.sleep,
        repo_base_dir: Path = Path("/tmp"),
        env: dict[str, str] | None = None,
    ) -> None:
        self.project_root = project_root
        self._run = runner
        self._run_output = output_runner
        self._sleep = sleeper
        self.repo_base_dir = repo_base_dir
        self.env = dict(os.environ)
        if env:
            self.env.update(env)
        self.retry = RetryPolicy(
            attempts=int(self.env.get("BUILD_RETRY_ATTEMPTS", "3")),
            delay_seconds=int(self.env.get("BUILD_RETRY_DELAY_SECONDS", "5")),
        ).normalized()
        self.base_images = {
            key: self.env.get(key, default)
            for key, default in DEFAULT_BASE_IMAGES.items()
        }

    def build_images_if_needed(
        self,
        config: DeployConfig,
        *,
        orchestrator: str,
        container_tool: str,
        force_rebuild: bool,
        dry_run: bool,
    ) -> None:
        if force_rebuild or not self._image_exists(IMAGE_HTTP, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self._build_artifacts_and_core_images(orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)
        elif not self._image_exists(IMAGE_EMULATOR, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self._build_artifacts_and_core_images(orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

        if force_rebuild or not self._image_exists(IMAGE_TFTP, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self._build_local_image(
                image=IMAGE_TFTP,
                context=self.project_root / "ochami-helm" / "tftp",
                container_tool=container_tool,
                build_args=[("BASE_IMAGE", self.base_images["BASE_IMAGE_TFTP"])],
                dry_run=dry_run,
            )
            self._load_into_minikube_if_needed(IMAGE_TFTP, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

        if force_rebuild or not self._image_exists(IMAGE_STORK_AGENT, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self._build_local_image(
                image=IMAGE_STORK_AGENT,
                context=self.project_root / "ochami-helm" / "stork-agent",
                container_tool=container_tool,
                build_args=[("BASE_IMAGE", self.base_images["BASE_IMAGE_STORK_AGENT"])],
                dry_run=dry_run,
            )
            self._load_into_minikube_if_needed(IMAGE_STORK_AGENT, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

        if force_rebuild or not self._image_exists(IMAGE_KEA_SIDECAR, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self._build_local_image(
                image=IMAGE_KEA_SIDECAR,
                context=self.project_root / "ochami-helm" / "kea-sidecar",
                container_tool=container_tool,
                build_args=[("BASE_IMAGE", self.base_images["BASE_IMAGE_KEA_SIDECAR"])],
                dry_run=dry_run,
            )
            self._load_into_minikube_if_needed(IMAGE_KEA_SIDECAR, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

        if force_rebuild or not self._image_exists(IMAGE_SMD, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self.build_smd(config=config, container_tool=container_tool, dry_run=dry_run)
            self._load_into_minikube_if_needed(IMAGE_SMD, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

        if force_rebuild or not self._image_exists(IMAGE_BSS, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self.build_bss(config=config, container_tool=container_tool, dry_run=dry_run)
            self._load_into_minikube_if_needed(IMAGE_BSS, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

        if force_rebuild or not self._image_exists(IMAGE_PCS, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run):
            self.build_pcs(config=config, container_tool=container_tool, dry_run=dry_run)
            self._load_into_minikube_if_needed(IMAGE_PCS, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

    def build_smd(self, *, config: DeployConfig, container_tool: str, dry_run: bool) -> None:
        repo_dir = self._prepare_repo_with_retry("smd", config.smd_ref, config.smd_repo_uri, dry_run=dry_run)
        self._run(["make", "clean"], cwd=repo_dir, check=False, dry_run=dry_run)
        self._run_with_retry(
            lambda: self._run(["make", "binaries"], cwd=repo_dir, dry_run=dry_run),
            "make binaries",
        )
        self._run_with_retry(
            lambda: self._run_container(container_tool, ["build", "-t", IMAGE_SMD, "."], cwd=repo_dir, dry_run=dry_run),
            f"build {IMAGE_SMD}",
        )

    def build_bss(self, *, config: DeployConfig, container_tool: str, dry_run: bool) -> None:
        repo_dir = self._prepare_repo_with_retry("bss", config.bss_ref, config.bss_repo_uri, dry_run=dry_run)
        self._run(["make", "clean"], cwd=repo_dir, check=False, dry_run=dry_run)
        self._run_with_retry(
            lambda: self._run(["make", "binaries"], cwd=repo_dir, dry_run=dry_run),
            "make binaries",
        )
        self._run_with_retry(
            lambda: self._run_container(container_tool, ["build", "-t", IMAGE_BSS, "."], cwd=repo_dir, dry_run=dry_run),
            f"build {IMAGE_BSS}",
        )

    def build_pcs(self, *, config: DeployConfig, container_tool: str, dry_run: bool) -> None:
        repo_dir = self._prepare_repo_with_retry("pcs", config.pcs_ref, config.pcs_repo_uri, dry_run=dry_run)
        self._run_with_retry(
            lambda: self._run_container(
                container_tool,
                ["build", "-f", "Dockerfile.build", "-t", IMAGE_PCS, "."],
                cwd=repo_dir,
                dry_run=dry_run,
            ),
            f"build {IMAGE_PCS}",
        )

    def _prepare_repo_with_retry(self, service: str, git_ref: str, repo_uri: str, *, dry_run: bool) -> Path:
        holder: dict[str, Path] = {}

        def _op() -> None:
            holder["path"] = self._prepare_repo(service=service, git_ref=git_ref, repo_uri=repo_uri, dry_run=dry_run)

        self._run_with_retry(_op, f"prepare_repo {service}")
        return holder["path"]

    def _prepare_repo(self, *, service: str, git_ref: str, repo_uri: str, dry_run: bool) -> Path:
        resolved_uri = repo_uri or DEFAULT_REPO_URIS[service]
        repo_name = resolved_uri.rsplit("/", 1)[-1].removesuffix(".git")
        repo_dir = self.repo_base_dir / repo_name

        if repo_dir.exists() and not (repo_dir / ".git").is_dir():
            raise RuntimeError(f"path exists but is not a git repository: {repo_dir}")

        if not (repo_dir / ".git").is_dir():
            self._run(["git", "clone", resolved_uri, str(repo_dir)], dry_run=dry_run)

        current_origin = self._run_output(["git", "remote", "get-url", "origin"], cwd=repo_dir, check=False, dry_run=dry_run).strip()
        if current_origin and current_origin != resolved_uri:
            self._run(["git", "remote", "set-url", "origin", resolved_uri], cwd=repo_dir, dry_run=dry_run)

        self._run(["git", "fetch", "--all", "--tags"], cwd=repo_dir, dry_run=dry_run)
        self._run(["git", "checkout", git_ref], cwd=repo_dir, dry_run=dry_run)
        self._run(["git", "pull"], cwd=repo_dir, dry_run=dry_run, check=False)
        self._run(["chmod", "-R", "a+rX", str(repo_dir)], dry_run=dry_run)
        return repo_dir

    def _image_exists(self, image: str, *, orchestrator: str, container_tool: str, dry_run: bool) -> bool:
        if dry_run:
            return False
        if orchestrator == "docker-compose":
            return self._run(["docker", "image", "inspect", image], check=False, dry_run=False) == 0
        if orchestrator == "quadlets":
            return self._run_container(container_tool, ["image", "exists", image], check=False, dry_run=False) == 0

        listing = self._run_output(["minikube", "image", "ls"], check=False, dry_run=False)
        return image in listing

    def _build_artifacts_and_core_images(self, *, orchestrator: str, container_tool: str, dry_run: bool) -> None:
        if dry_run:
            self._run_container(container_tool, ["build", "-t", "custom-image-builder-sles", "."], dry_run=True)
            self._build_local_image(
                image=IMAGE_HTTP,
                context=self.project_root / "ochami-helm" / "http-server",
                container_tool=container_tool,
                build_args=[("BASE_IMAGE", self.base_images["BASE_IMAGE_HTTP_SERVER"])],
                dry_run=True,
            )
            self._build_local_image(
                image=IMAGE_EMULATOR,
                context=self.project_root / "ochami-helm" / "redfish-emulator",
                container_tool=container_tool,
                build_args=[("BASE_IMAGE", self.base_images["BASE_IMAGE_REDFISH_EMULATOR"])],
                dry_run=True,
            )
            self._load_into_minikube_if_needed(IMAGE_HTTP, orchestrator=orchestrator, container_tool=container_tool, dry_run=True)
            self._load_into_minikube_if_needed(IMAGE_EMULATOR, orchestrator=orchestrator, container_tool=container_tool, dry_run=True)
            return

        with tempfile.TemporaryDirectory() as tmp:
            build_dir = Path(tmp)
            eth0_xml = build_dir / "eth0.xml"
            dockerfile = build_dir / "Dockerfile"
            eth0_xml.write_text(
                (
                    "<interface>\n"
                    "  <name>eth0</name>\n"
                    "  <control><mode>boot</mode></control>\n"
                    "  <ipv4>\n"
                    "    <enabled>true</enabled>\n"
                    "    <dhcp><enabled>true</enabled></dhcp>\n"
                    "  </ipv4>\n"
                    "</interface>\n"
                ),
                encoding="utf-8",
            )
            dockerfile.write_text(
                (
                    f"FROM {self.base_images['BASE_IMAGE_SLES_BUILDER']}\n"
                    "RUN zypper ref && zypper install -y kernel-default dracut squashfs iproute2 util-linux shadow device-mapper tar dhcp-client curl udev\n"
                    "RUN echo 'root:root' | chpasswd\n"
                    "RUN mkdir -p /tmp/netconfig\n"
                    "COPY eth0.xml /tmp/netconfig/eth0.xml\n"
                    "RUN KVER=$(ls /lib/modules | head -n 1) && dracut -v --add \"network dmsquash-live livenet\" --include /tmp/netconfig/eth0.xml /etc/wicked/ifconfig/eth0.xml --no-hostonly --kver $KVER /boot/initrd.img\n"
                ),
                encoding="utf-8",
            )

            self._run_container(container_tool, ["build", "-t", "custom-image-builder-sles", str(build_dir)], dry_run=False)
            container_id = self._run_container_output(container_tool, ["create", "custom-image-builder-sles"], dry_run=False).strip()
            if not container_id:
                raise RuntimeError("failed to create custom-image-builder-sles container")

            initramfs_path = self.project_root / "initramfs-lts"
            self._run_container(container_tool, ["cp", f"{container_id}:/boot/initrd.img", str(initramfs_path)], dry_run=False)

            boot_tmp = self.project_root / "boot_tmp"
            modules_tmp = self.project_root / "modules_tmp"
            usr_modules_tmp = self.project_root / "usr_modules_tmp"
            for path in (boot_tmp, modules_tmp, usr_modules_tmp):
                if path.exists():
                    shutil.rmtree(path)

            boot_tmp.mkdir(parents=True, exist_ok=True)
            self._run_container(container_tool, ["cp", f"{container_id}:/boot/.", str(boot_tmp)], dry_run=False)
            self._run_container(container_tool, ["cp", f"{container_id}:/lib/modules", str(modules_tmp)], dry_run=False, check=False)
            self._run_container(container_tool, ["cp", f"{container_id}:/usr/lib/modules", str(usr_modules_tmp)], dry_run=False, check=False)

            vmlinuz = self._find_kernel_file([boot_tmp, modules_tmp, usr_modules_tmp])
            if vmlinuz is None:
                raise RuntimeError("vmlinuz not found in extracted container paths")
            shutil.copy2(vmlinuz, self.project_root / "vmlinuz-lts")

            rootfs_tar = build_dir / "rootfs.tar"
            tool_cmd = shlex.join([*self._tool_parts(container_tool), "export", container_id])
            self._run(["bash", "-lc", f"{tool_cmd} > {shlex.quote(str(rootfs_tar))}"], dry_run=False)

            full_root = build_dir / "full_root"
            full_root.mkdir(parents=True, exist_ok=True)
            with tarfile.open(rootfs_tar, mode="r") as archive:
                archive.extractall(path=full_root)

            if not command_exists("mksquashfs"):
                raise RuntimeError("mksquashfs is required to build rootfs artifacts")

            opensuse_sq = build_dir / "rootfs-opensuse.squashfs"
            ubuntu_sq = build_dir / "rootfs-ubuntu.squashfs"
            self._prepare_rootfs_variant(full_root, "opensuse", "opensuse", opensuse_sq)
            self._prepare_rootfs_variant(full_root, "ubuntu", "ubuntu", ubuntu_sq)

            self._run_container(container_tool, ["rm", container_id], dry_run=False, check=False)
            self._run_container(container_tool, ["rmi", "-f", "custom-image-builder-sles"], dry_run=False, check=False)

            artifacts_root = self.project_root / "ochami-helm" / "http-server" / "artifacts"
            opensuse_dir = artifacts_root / "opensuse"
            ubuntu_dir = artifacts_root / "ubuntu"
            for path in (opensuse_dir, ubuntu_dir):
                if path.exists():
                    shutil.rmtree(path)
                path.mkdir(parents=True, exist_ok=True)
            for shared in ("vmlinuz-lts", "initramfs-lts"):
                shutil.copy2(self.project_root / shared, opensuse_dir / shared)
                shutil.copy2(self.project_root / shared, ubuntu_dir / shared)
            shutil.move(str(opensuse_sq), str(opensuse_dir / "rootfs.squashfs"))
            shutil.move(str(ubuntu_sq), str(ubuntu_dir / "rootfs.squashfs"))

        self._build_local_image(
            image=IMAGE_HTTP,
            context=self.project_root / "ochami-helm" / "http-server",
            container_tool=container_tool,
            build_args=[("BASE_IMAGE", self.base_images["BASE_IMAGE_HTTP_SERVER"])],
            dry_run=dry_run,
        )
        self._load_into_minikube_if_needed(IMAGE_HTTP, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

        self._build_local_image(
            image=IMAGE_EMULATOR,
            context=self.project_root / "ochami-helm" / "redfish-emulator",
            container_tool=container_tool,
            build_args=[("BASE_IMAGE", self.base_images["BASE_IMAGE_REDFISH_EMULATOR"])],
            dry_run=dry_run,
        )
        self._load_into_minikube_if_needed(IMAGE_EMULATOR, orchestrator=orchestrator, container_tool=container_tool, dry_run=dry_run)

    def _prepare_rootfs_variant(self, source_root: Path, variant_name: str, prompt_label: str, output_squashfs: Path) -> None:
        variant_root = source_root.parent / f"full_root_{variant_name}"
        if variant_root.exists():
            shutil.rmtree(variant_root)
        shutil.copytree(source_root, variant_root, symlinks=True)
        profile_dir = variant_root / "etc" / "profile.d"
        profile_dir.mkdir(parents=True, exist_ok=True)
        (profile_dir / "99-openchami-ps1.sh").write_text(
            (
                "#!/bin/sh\n"
                "if [ \"$(id -u)\" -eq 0 ]; then\n"
                "    xname=\"$(hostname -s 2>/dev/null || hostname)\"\n"
                f"    export PS1=\"<${{xname}}> {prompt_label} : \"\n"
                "fi\n"
            ),
            encoding="utf-8",
        )
        self._run(
            [
                "mksquashfs",
                str(variant_root),
                str(output_squashfs),
                "-noappend",
                "-wildcards",
                "-e",
                "proc/*",
                "-e",
                "sys/*",
                "-e",
                "dev/*",
                "-e",
                "tmp/*",
                "-e",
                "boot/*",
                "-e",
                "var/cache/zypp/*",
            ]
        )

    def _find_kernel_file(self, roots: list[Path]) -> Path | None:
        patterns = ["vmlinuz*", "Image*", "bzImage*", "linux*", "kernel*", "vmlinux*"]
        for root in roots:
            if not root.exists():
                continue
            for path in root.rglob("*"):
                if not path.is_file():
                    continue
                if any(fnmatch.fnmatch(path.name, pattern) for pattern in patterns):
                    return path
        return None

    def _load_into_minikube_if_needed(self, image: str, *, orchestrator: str, container_tool: str, dry_run: bool) -> None:
        if orchestrator != "minikube":
            return
        runtime = self._tool_parts(container_tool)[-1]
        if runtime == "docker":
            self._run(["bash", "-lc", f"docker save {shlex.quote(image)} | minikube image load -"], dry_run=dry_run)
            return
        self._run(["minikube", "image", "load", image], dry_run=dry_run)

    def _build_local_image(
        self,
        *,
        image: str,
        context: Path,
        container_tool: str,
        build_args: list[tuple[str, str]],
        dry_run: bool,
    ) -> None:
        runtime = self._tool_parts(container_tool)[-1]
        args: list[str] = []
        for key, value in build_args:
            args.extend(["--build-arg", f"{key}={value}"])

        if runtime != "docker":
            self._run_container(container_tool, ["build", *args, "-t", image, str(context)], dry_run=dry_run)
            return

        self._run(["docker", "build", *args, "-t", image, str(context)], dry_run=dry_run)
        inspect_rc = self._run(["docker", "image", "inspect", image], check=False, dry_run=dry_run)
        if inspect_rc == 0:
            return
        self._run(["docker", "buildx", "build", "--load", *args, "-t", image, str(context)], dry_run=dry_run)

    def _run_container(
        self,
        container_tool: str,
        args: list[str],
        *,
        cwd: Path | None = None,
        dry_run: bool,
        check: bool = True,
    ) -> int:
        return self._run([*self._tool_parts(container_tool), *args], cwd=cwd, dry_run=dry_run, check=check)

    def _run_container_output(
        self,
        container_tool: str,
        args: list[str],
        *,
        cwd: Path | None = None,
        dry_run: bool,
        check: bool = True,
    ) -> str:
        return self._run_output([*self._tool_parts(container_tool), *args], cwd=cwd, dry_run=dry_run, check=check)

    def _tool_parts(self, container_tool: str) -> list[str]:
        return shlex.split(container_tool)

    def _run_with_retry(self, func: Callable[[], None], description: str) -> None:
        last_error: Exception | None = None
        for attempt in range(1, self.retry.attempts + 1):
            try:
                func()
                return
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                if attempt < self.retry.attempts:
                    self._sleep(self.retry.delay_seconds)
        raise RuntimeError(f"command failed after {self.retry.attempts} attempts: {description}") from last_error
