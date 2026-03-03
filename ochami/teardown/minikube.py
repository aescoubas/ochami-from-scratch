from __future__ import annotations

import json
from pathlib import Path

from ochami.config import DeploymentMethod, TeardownConfig
from ochami.network import NetworkManager
from ochami.system import (
    FS_PROTECTED_REGULAR_STATE_FILE,
    cleanup_build_artifacts,
    destroy_vms,
    restore_fs_protected_regular_if_managed,
)
from ochami.teardown.base import BaseTeardown
from ochami.utils import command_exists, is_macos, run, run_output


MINIKUBE_REMOVE_IMAGES = [
    "localhost/http-server:latest",
    "localhost/tftp:latest",
    "localhost/smd:local-smd",
    "localhost/bss:local-bss",
    "localhost/pcs:local-pcs",
    "ghcr.io/openchami/cloud-init:v1.2.3",
    "localhost/stork-agent:latest",
    "localhost/kea-sidecar:latest",
    "signalorange/stork:ubuntu24.04-1.19.0",
]


class MinikubeTeardown(BaseTeardown):
    def __init__(
        self,
        *,
        project_root: Path | None = None,
        runner=run,
        output_runner=run_output,
        network: NetworkManager | None = None,
        macos: bool | None = None,
        has_minikube: bool | None = None,
        has_docker: bool | None = None,
        fs_state_path: Path = FS_PROTECTED_REGULAR_STATE_FILE,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self._run = runner
        self._run_output = output_runner
        self._is_macos = is_macos() if macos is None else macos
        self._has_minikube = command_exists("minikube") if has_minikube is None else has_minikube
        self._has_docker = command_exists("docker") if has_docker is None else has_docker
        self._fs_state_path = fs_state_path
        self.network = network or NetworkManager(self.project_root, runner=runner, output_runner=output_runner, macos=self._is_macos)

    def validate(self, config: TeardownConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.MINIKUBE:
            raise ValueError("MinikubeTeardown only supports --method minikube")

    def teardown(self, config: TeardownConfig, dry_run: bool) -> None:
        self._destroy_vms(config, dry_run=dry_run)
        self.network.cleanup_for_minikube(config, dry_run=dry_run)
        self._delete_minikube_cluster(dry_run=dry_run)
        if config.remove_images:
            self._remove_images(dry_run=dry_run)
        self._cleanup_artifacts(dry_run=dry_run)
        if config.remove_images and not self._is_macos:
            self._run(["sudo", "rm", "-rf", "/opt/cni"], dry_run=dry_run, check=False)
        self._restore_fs_protected_regular(dry_run=dry_run)

    def _destroy_vms(self, config: TeardownConfig, dry_run: bool) -> None:
        destroy_vms(
            config.vm_name,
            runner=self._run,
            output_runner=self._run_output,
            dry_run=dry_run,
            macos=self._is_macos,
        )

    def _delete_minikube_cluster(self, dry_run: bool) -> None:
        if not self._has_minikube and not dry_run:
            return

        if self._is_macos:
            self._run(["minikube", "delete"], dry_run=dry_run, check=False)
            return

        profile_output = self._run_output(
            ["minikube", "profile", "list", "-o", "json"],
            dry_run=dry_run,
            check=False,
        )
        if _minikube_uses_none_driver(profile_output):
            self._run(["sudo", "-E", "minikube", "delete"], dry_run=dry_run, check=False)
        else:
            self._run(["minikube", "delete"], dry_run=dry_run, check=False)

    def _remove_images(self, dry_run: bool) -> None:
        if not self._has_docker and not dry_run:
            return
        for image in MINIKUBE_REMOVE_IMAGES:
            rc = self._run(["docker", "image", "inspect", image], dry_run=dry_run, check=False)
            if rc == 0:
                self._run(["docker", "rmi", image], dry_run=dry_run, check=False)

    def _cleanup_artifacts(self, dry_run: bool) -> None:
        cleanup_build_artifacts(self.project_root, dry_run=dry_run)

    def _restore_fs_protected_regular(self, dry_run: bool) -> None:
        restore_fs_protected_regular_if_managed(
            runner=self._run,
            output_runner=self._run_output,
            fs_state_path=self._fs_state_path,
            dry_run=dry_run,
            macos=self._is_macos,
        )


def _minikube_uses_none_driver(profile_output: str) -> bool:
    try:
        payload = json.loads(profile_output)
    except json.JSONDecodeError:
        return '"Driver": "none"' in profile_output or '"Driver":"none"' in profile_output

    candidates: list[dict[str, object]] = []
    if isinstance(payload, dict):
        valid = payload.get("valid")
        if isinstance(valid, list):
            candidates.extend(item for item in valid if isinstance(item, dict))
        profiles = payload.get("profiles")
        if isinstance(profiles, list):
            candidates.extend(item for item in profiles if isinstance(item, dict))

    for item in candidates:
        driver = item.get("Driver")
        if isinstance(driver, str) and driver == "none":
            return True
    return False
