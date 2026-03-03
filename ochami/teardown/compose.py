from __future__ import annotations

from pathlib import Path

from ochami.config import DeploymentMethod, TeardownConfig
from ochami.network import NetworkManager
from ochami.teardown.base import BaseTeardown
from ochami.utils import run


COMPOSE_REMOVE_IMAGES = [
    "localhost/http-server:latest",
    "localhost/tftp:latest",
    "localhost/smd:local-smd",
    "localhost/bss:local-bss",
    "localhost/redfish-emulator:latest",
    "localhost/pcs:local-pcs",
    "localhost/stork-agent:latest",
    "localhost/kea-sidecar:latest",
    "signalorange/stork:ubuntu24.04-1.19.0",
]


class ComposeTeardown(BaseTeardown):
    def __init__(self, *, project_root: Path | None = None, runner=run, network: NetworkManager | None = None) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self.compose_dir = self.project_root / "ochami-docker-compose"
        self._run = runner
        self.network = network or NetworkManager(self.project_root, runner=runner)

    def validate(self, config: TeardownConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.DOCKER_COMPOSE:
            raise ValueError("ComposeTeardown only supports --method docker-compose")

    def teardown(self, config: TeardownConfig, dry_run: bool) -> None:
        self._destroy_vms(config, dry_run=dry_run)
        self._compose_down(dry_run=dry_run)
        self.network.cleanup_for_compose(config, dry_run=dry_run)
        self._remove_generated_files(dry_run=dry_run)
        if config.remove_images:
            self._remove_images(dry_run=dry_run)
        self._cleanup_artifacts(dry_run=dry_run)

    def _destroy_vms(self, config: TeardownConfig, dry_run: bool) -> None:
        common_sh = self.project_root / "scripts" / "common.sh"
        self._run(
            [
                "bash",
                "-lc",
                f"source '{common_sh}' && destroy_vms '{config.vm_name}'",
            ],
            dry_run=dry_run,
            check=False,
        )

    def _compose_down(self, dry_run: bool) -> None:
        files = [self.compose_dir / "docker-compose.yml"]
        if (self.compose_dir / "docker-compose.macos.yml").is_file():
            files.append(self.compose_dir / "docker-compose.macos.yml")

        cmd: list[str] = ["docker", "compose", "-p", "ochami"]
        for file_path in files:
            if file_path.is_file():
                cmd.extend(["-f", str(file_path)])
        cmd.extend(["down", "-v", "--remove-orphans"])
        self._run(cmd, dry_run=dry_run, check=False)

    def _remove_generated_files(self, dry_run: bool) -> None:
        for path in [
            self.compose_dir / ".env",
            self.compose_dir / "configs" / "kea-dhcp4.conf",
            self.compose_dir / "configs" / "nginx-default.conf",
            self.compose_dir / "configs" / "boot.ipxe",
            self.compose_dir / "configs" / "stork-server.env",
        ]:
            if path.exists() and not dry_run:
                path.unlink()

    def _remove_images(self, dry_run: bool) -> None:
        for image in COMPOSE_REMOVE_IMAGES:
            rc = self._run(["docker", "image", "inspect", image], dry_run=dry_run, check=False)
            if rc == 0:
                self._run(["docker", "rmi", image], dry_run=dry_run, check=False)

    def _cleanup_artifacts(self, dry_run: bool) -> None:
        common_sh = self.project_root / "scripts" / "common.sh"
        self._run(
            [
                "bash",
                "-lc",
                f"source '{common_sh}' && cleanup_build_artifacts && restore_fs_protected_regular_if_managed",
            ],
            dry_run=dry_run,
            check=False,
        )
