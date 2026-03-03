from __future__ import annotations

from pathlib import Path

from ochami.config import DeployConfig, DeployMode, TeardownConfig
from ochami.utils import is_macos, run, run_output


class NetworkManager:
    def __init__(self, project_root: Path, runner=run, output_runner=run_output, macos: bool | None = None) -> None:
        self.project_root = project_root
        self._run = runner
        self._run_output = output_runner
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

    def configure_for_minikube(self, config: DeployConfig, dry_run: bool) -> tuple[str, str]:
        if self._is_macos:
            host_ip = self._run_output(["minikube", "ip"], check=False, dry_run=dry_run).strip()
            if not host_ip and not dry_run:
                host_ip = "127.0.0.1"
            if not host_ip:
                host_ip = config.pxe_ip
            return host_ip, config.pxe_interface

        common_sh = self.project_root / "scripts" / "common.sh"
        active_interface = config.pxe_interface
        bridge_interface = config.phy_iface

        if config.mode == DeployMode.HARDWARE:
            resolved = self._run_output(
                [
                    "bash",
                    "-lc",
                    (
                        f"source '{common_sh}' && "
                        f"configure_hardware_network '{config.pxe_interface}' '{config.phy_iface}'"
                    ),
                ],
                dry_run=dry_run,
            ).strip()
            if resolved:
                active_interface = resolved
            # Match bash behavior: once hardware interface is resolved, pass empty PHY_IFACE to setup script.
            bridge_interface = ""

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
                bridge_interface,
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
        return config.pxe_ip, active_interface

    def cleanup_for_minikube(self, config: TeardownConfig, dry_run: bool) -> None:
        self.cleanup_for_compose(config, dry_run=dry_run)
