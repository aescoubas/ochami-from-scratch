from __future__ import annotations

from pathlib import Path

from ochami.config import DeploymentMethod, TeardownConfig
from ochami.network import NetworkManager
from ochami.system import (
    FS_PROTECTED_REGULAR_STATE_FILE,
    cleanup_build_artifacts,
    destroy_vms,
    restore_fs_protected_regular_if_managed,
)
from ochami.build import IMAGE_CLOUD_INIT
from ochami.teardown.base import BaseTeardown
from ochami.utils import is_macos, parse_env_file, run, run_output


COMPOSE_REMOVE_IMAGES = [
    "localhost/http-server:latest",
    "localhost/tftp:latest",
    "localhost/smd:local-smd",
    "localhost/bss:local-bss",
    "localhost/redfish-emulator:latest",
    "localhost/pcs:local-pcs",
    IMAGE_CLOUD_INIT,
    "localhost/stork-agent:latest",
    "localhost/kea-sidecar:latest",
    "signalorange/stork:ubuntu24.04-1.19.0",
]

COMPOSE_REQUIRED_ENV_DEFAULTS = {
    "POSTGRES_PASSWORD": "teardown-postgres-password",
    "SMD_DB_PASSWORD": "teardown-smd-password",
    "BSS_DB_PASSWORD": "teardown-bss-password",
    "KEA_DB_PASSWORD": "teardown-kea-password",
    "PCS_DB_PASSWORD": "teardown-pcs-password",
    "STORK_DB_PASSWORD": "teardown-stork-password",
}


class ComposeTeardown(BaseTeardown):
    def __init__(
        self,
        *,
        project_root: Path | None = None,
        runner=run,
        output_runner=run_output,
        network: NetworkManager | None = None,
        fs_state_path: Path = FS_PROTECTED_REGULAR_STATE_FILE,
        macos: bool | None = None,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self.compose_dir = self.project_root / "ochami-docker-compose"
        self._run = runner
        self._run_output = output_runner
        self._is_macos = is_macos() if macos is None else macos
        self._fs_state_path = fs_state_path
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
        destroy_vms(
            config.vm_name,
            runner=self._run,
            output_runner=self._run_output,
            dry_run=dry_run,
            macos=self._is_macos,
        )

    def _compose_down(self, dry_run: bool) -> None:
        env_file = self.compose_dir / ".env"
        files = [self.compose_dir / "docker-compose.yml"]
        if self._is_macos and (self.compose_dir / "docker-compose.macos.yml").is_file():
            files.append(self.compose_dir / "docker-compose.macos.yml")

        cmd: list[str] = ["docker", "compose", "-p", "ochami"]
        for file_path in files:
            if file_path.is_file():
                cmd.extend(["-f", str(file_path)])
        if env_file.is_file():
            cmd.extend(["--env-file", str(env_file)])
        cmd.extend(["down", "-v", "--remove-orphans"])
        self._run(cmd, dry_run=dry_run, check=False, env=self._compose_env())

    def _compose_env(self) -> dict[str, str]:
        env_values = parse_env_file(self.project_root / ".openchami-secrets.env")
        env_values.update(parse_env_file(self.compose_dir / ".env"))
        for key, default in COMPOSE_REQUIRED_ENV_DEFAULTS.items():
            env_values.setdefault(key, default)
        return env_values

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
        cleanup_build_artifacts(self.project_root, dry_run=dry_run)
        restore_fs_protected_regular_if_managed(
            runner=self._run,
            output_runner=self._run_output,
            fs_state_path=self._fs_state_path,
            dry_run=dry_run,
            macos=self._is_macos,
        )
