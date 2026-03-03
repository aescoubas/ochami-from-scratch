from __future__ import annotations

from pathlib import Path

from ochami.config import DeployConfig, DeployMode, TeardownConfig
from ochami.utils import is_macos, run


class NetworkManager:
    def __init__(self, project_root: Path, runner=run, macos: bool | None = None) -> None:
        self.project_root = project_root
        self._run = runner
        self._is_macos = is_macos() if macos is None else macos

    def configure_for_compose(self, config: DeployConfig, dry_run: bool) -> str:
        if self._is_macos:
            return config.pxe_ip

        active_interface = config.phy_iface if (config.mode == DeployMode.HARDWARE and config.phy_iface) else config.pxe_interface
        common_sh = self.project_root / "scripts" / "common.sh"

        if config.mode == DeployMode.LIBVIRT:
            self._run(
                ["bash", "-lc", f"source '{common_sh}' && configure_libvirt_network '{active_interface}'"],
                dry_run=dry_run,
            )

        self._run(
            [
                str(self.project_root / "scripts" / "setup_minikube_net.sh"),
                active_interface,
                config.pxe_ip,
                str(config.pxe_cidr),
                config.phy_iface,
            ],
            dry_run=dry_run,
        )
        self._run(
            [
                "bash",
                "-lc",
                (
                    f"source '{common_sh}' && "
                    f"check_dhcp_port_conflict '{active_interface}' '{config.dhcp_conflict_policy.value}' && "
                    f"configure_firewall '{active_interface}'"
                ),
            ],
            dry_run=dry_run,
        )
        return config.pxe_ip

    def cleanup_for_compose(self, config: TeardownConfig, dry_run: bool) -> None:
        if self._is_macos:
            return
        common_sh = self.project_root / "scripts" / "common.sh"
        self._run(
            [
                "bash",
                "-lc",
                (
                    f"source '{common_sh}' && "
                    "destroy_pxe_network && "
                    f"cleanup_host_networking '{config.pxe_interface}' '{config.pxe_ip}' '{config.pxe_cidr}'"
                ),
            ],
            dry_run=dry_run,
            check=False,
        )

    def configure_for_quadlets(self, config: DeployConfig, dry_run: bool) -> str:
        return self.configure_for_compose(config, dry_run=dry_run)

    def cleanup_for_quadlets(self, config: TeardownConfig, dry_run: bool) -> None:
        self.cleanup_for_compose(config, dry_run=dry_run)
