from __future__ import annotations

import shutil
from pathlib import Path
import re

from ochami.config import DeploymentMethod, TeardownConfig
from ochami.network import NetworkManager
from ochami.system import (
    FS_PROTECTED_REGULAR_STATE_FILE,
    cleanup_build_artifacts,
    destroy_vms,
    restore_fs_protected_regular_if_managed,
)
from ochami.teardown.base import BaseTeardown
from ochami.utils import is_macos, run, run_output


QUADLETS_REMOVE_IMAGES = [
    "localhost/http-server:latest",
    "localhost/tftp:latest",
    "localhost/smd:local-smd",
    "localhost/bss:local-bss",
    "localhost/pcs:local-pcs",
    "ghcr.io/openchami/cloud-init:v1.4.0",
    "localhost/stork-agent:latest",
    "localhost/kea-sidecar:latest",
    "localhost/redfish-emulator:latest",
    "signalorange/stork:ubuntu24.04-1.19.0",
    "postgres:11.5-alpine",
    "jonasal/kea-admin:3.1.4",
    "jonasal/kea-dhcp4:3.1.4",
    "jonasal/kea-ctrl-agent:3.1.4",
]

_QUADLET_SERVICE_PATTERN = re.compile(
    r"^(?:"
    r"bss(?:-init)?|"
    r"cloud-init-server|"
    r"http-server|"
    r"kea(?:-ctrl-agent|-init|-sidecar)?|"
    r"pcs(?:-init)?|"
    r"postgres|"
    r"redfish-emulator-\d+|"
    r"smd(?:-init)?|"
    r"stork-agent|"
    r"stork-server|"
    r"tftp"
    r")\.service$"
)


class QuadletsTeardown(BaseTeardown):
    def __init__(
        self,
        *,
        project_root: Path | None = None,
        runner=run,
        output_runner=run_output,
        network: NetworkManager | None = None,
        quadlets_install_dir: Path | None = None,
        openchami_config_dir: Path | None = None,
        systemd_dir: Path | None = None,
        fs_state_path: Path = FS_PROTECTED_REGULAR_STATE_FILE,
        linux: bool | None = None,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self._run = runner
        self._run_output = output_runner
        self._linux = (not is_macos()) if linux is None else linux
        self.network = network or NetworkManager(self.project_root, runner=runner)
        self.quadlets_install_dir = quadlets_install_dir or Path("/etc/containers/systemd")
        self.openchami_config_dir = openchami_config_dir or Path("/etc/openchami")
        self.systemd_dir = systemd_dir or Path("/etc/systemd/system")
        self._fs_state_path = fs_state_path

    def validate(self, config: TeardownConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.QUADLETS:
            raise ValueError("QuadletsTeardown only supports --method quadlets")
        if not self._linux:
            raise ValueError("quadlets teardown requires Linux/systemd")

    def teardown(self, config: TeardownConfig, dry_run: bool) -> None:
        self._destroy_vms(config, dry_run=dry_run)
        quadlet_services = self._quadlet_service_names(dry_run=dry_run)

        self._run(["sudo", "systemctl", "stop", "openchami.target"], dry_run=dry_run, check=False)
        self._run(["sudo", "systemctl", "stop", "ochami.service"], dry_run=dry_run, check=False)
        for service in quadlet_services:
            self._run(["sudo", "systemctl", "stop", service], dry_run=dry_run, check=False)

        if not dry_run:
            try:
                container_units = list(self.quadlets_install_dir.glob("*.container"))
            except PermissionError:
                self._run(
                    [
                        "sudo",
                        "find",
                        str(self.quadlets_install_dir),
                        "-maxdepth",
                        "1",
                        "-type",
                        "f",
                        "-name",
                        "*.container",
                        "-delete",
                    ],
                    dry_run=dry_run,
                    check=False,
                )
                container_units = []

            for path in container_units:
                self._unlink_file(path, dry_run=dry_run)
            legacy_kube = self.quadlets_install_dir / "ochami.kube"
            legacy_yaml = self.quadlets_install_dir / "ochami.yaml"
            self._unlink_file(legacy_kube, dry_run=dry_run)
            self._unlink_file(legacy_yaml, dry_run=dry_run)

            target = self.systemd_dir / "openchami.target"
            self._unlink_file(target, dry_run=dry_run)

            if self.openchami_config_dir.exists():
                self._remove_tree(self.openchami_config_dir, dry_run=dry_run)

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

        cleanup_build_artifacts(self.project_root, dry_run=dry_run)
        restore_fs_protected_regular_if_managed(
            runner=self._run,
            output_runner=self._run_output,
            fs_state_path=self._fs_state_path,
            dry_run=dry_run,
            macos=not self._linux,
        )

    def _destroy_vms(self, config: TeardownConfig, dry_run: bool) -> None:
        destroy_vms(
            config.vm_name,
            runner=self._run,
            output_runner=self._run_output,
            dry_run=dry_run,
            macos=not self._linux,
        )

    def _unlink_file(self, path: Path, *, dry_run: bool) -> None:
        if not path.exists():
            return
        try:
            path.unlink()
        except PermissionError:
            self._run(["sudo", "rm", "-f", str(path)], dry_run=dry_run, check=False)

    def _remove_tree(self, path: Path, *, dry_run: bool) -> None:
        try:
            shutil.rmtree(path)
        except PermissionError:
            self._run(["sudo", "rm", "-rf", str(path)], dry_run=dry_run, check=False)

    def _quadlet_service_names(self, *, dry_run: bool) -> list[str]:
        services: set[str] = set()
        try:
            services.update(f"{path.stem}.service" for path in self.quadlets_install_dir.glob("*.container"))
        except PermissionError:
            pass

        systemd_listing = self._run_output(
            ["sudo", "systemctl", "list-units", "--type=service", "--all", "--no-legend", "--no-pager"],
            check=False,
            dry_run=dry_run,
        )
        for line in systemd_listing.splitlines():
            match = re.search(r"([A-Za-z0-9_.@:-]+\.service)", line)
            if match is None:
                continue
            unit = match.group(1)
            if _QUADLET_SERVICE_PATTERN.fullmatch(unit):
                services.add(unit)

        return sorted(services)
