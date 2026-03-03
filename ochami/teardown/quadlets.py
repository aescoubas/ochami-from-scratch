from __future__ import annotations

import shutil
from pathlib import Path

from ochami.config import DeploymentMethod, TeardownConfig
from ochami.network import NetworkManager
from ochami.teardown.base import BaseTeardown
from ochami.utils import is_macos, run


QUADLETS_REMOVE_IMAGES = [
    "localhost/http-server:latest",
    "localhost/tftp:latest",
    "localhost/smd:local-smd",
    "localhost/bss:local-bss",
    "localhost/pcs:local-pcs",
    "ghcr.io/openchami/cloud-init:v1.2.3",
    "localhost/stork-agent:latest",
    "localhost/kea-sidecar:latest",
    "localhost/redfish-emulator:latest",
    "signalorange/stork:ubuntu24.04-1.19.0",
    "postgres:11.5-alpine",
    "jonasal/kea-admin:3.1.4",
    "jonasal/kea-dhcp4:3.1.4",
    "jonasal/kea-ctrl-agent:3.1.4",
]


class QuadletsTeardown(BaseTeardown):
    def __init__(
        self,
        *,
        project_root: Path | None = None,
        runner=run,
        network: NetworkManager | None = None,
        quadlets_install_dir: Path | None = None,
        openchami_config_dir: Path | None = None,
        systemd_dir: Path | None = None,
        linux: bool | None = None,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self._run = runner
        self._linux = (not is_macos()) if linux is None else linux
        self.network = network or NetworkManager(self.project_root, runner=runner)
        self.quadlets_install_dir = quadlets_install_dir or Path("/etc/containers/systemd")
        self.openchami_config_dir = openchami_config_dir or Path("/etc/openchami")
        self.systemd_dir = systemd_dir or Path("/etc/systemd/system")

    def validate(self, config: TeardownConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.QUADLETS:
            raise ValueError("QuadletsTeardown only supports --method quadlets")
        if not self._linux:
            raise ValueError("quadlets teardown requires Linux/systemd")

    def teardown(self, config: TeardownConfig, dry_run: bool) -> None:
        self._destroy_vms(config, dry_run=dry_run)

        self._run(["sudo", "systemctl", "stop", "openchami.target"], dry_run=dry_run, check=False)
        self._run(["sudo", "systemctl", "stop", "ochami.service"], dry_run=dry_run, check=False)

        if not dry_run:
            for path in self.quadlets_install_dir.glob("*.container"):
                path.unlink()
            legacy_kube = self.quadlets_install_dir / "ochami.kube"
            legacy_yaml = self.quadlets_install_dir / "ochami.yaml"
            if legacy_kube.exists():
                legacy_kube.unlink()
            if legacy_yaml.exists():
                legacy_yaml.unlink()

            target = self.systemd_dir / "openchami.target"
            if target.exists():
                target.unlink()

            if self.openchami_config_dir.exists():
                shutil.rmtree(self.openchami_config_dir)

        self._run(["sudo", "systemctl", "daemon-reload"], dry_run=dry_run, check=False)

        for volume in ("systemd-postgres-data", "systemd-kea-sockets"):
            rc = self._run(["sudo", "podman", "volume", "exists", volume], dry_run=dry_run, check=False)
            if rc == 0:
                self._run(["sudo", "podman", "volume", "rm", volume], dry_run=dry_run, check=False)

        self.network.cleanup_for_quadlets(config, dry_run=dry_run)

        if config.remove_images:
            for image in QUADLETS_REMOVE_IMAGES:
                rc = self._run(["sudo", "podman", "image", "inspect", image], dry_run=dry_run, check=False)
                if rc == 0:
                    self._run(["sudo", "podman", "rmi", image], dry_run=dry_run, check=False)

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

    def _destroy_vms(self, config: TeardownConfig, dry_run: bool) -> None:
        common_sh = self.project_root / "scripts" / "common.sh"
        self._run(
            ["bash", "-lc", f"source '{common_sh}' && destroy_vms '{config.vm_name}'"],
            dry_run=dry_run,
            check=False,
        )
