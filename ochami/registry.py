from __future__ import annotations

import csv
from pathlib import Path
import time
from urllib import error, request

from ochami.config import DeployConfig, DiscoveryMethod
from ochami.utils import is_macos, run, validate_ip, validate_mac


BSS_PORT = 27778
HTTP_PORT = 80


class RegistryManager:
    def __init__(self, project_root: Path, runner=run, macos: bool | None = None) -> None:
        self.project_root = project_root
        self._runner = runner
        self._is_macos = is_macos() if macos is None else macos

    def wait_for_services(self, checks: list[tuple[str, str]], dry_run: bool) -> None:
        if dry_run:
            return
        for name, url in checks:
            self._wait_for_url(url, name)

    def register_bss_defaults(self, host: str, host_ip: str, extra_params: str, dry_run: bool) -> None:
        if dry_run:
            return
        artifacts_url = f"http://{host_ip}:{HTTP_PORT}/artifacts/opensuse"
        params = f"console=ttyS0 ip=dhcp rd.neednet=1 root=live:{artifacts_url}/rootfs.squashfs"
        if extra_params:
            params = f"{params} {extra_params}"
        body = (
            "{"
            '"hosts":["Default"],'
            f'"kernel":"{artifacts_url}/vmlinuz-lts",'
            f'"initrd":"{artifacts_url}/initramfs-lts",'
            f'"params":"{params}"'
            "}"
        ).encode("utf-8")

        url = f"http://{host}:{BSS_PORT}/boot/v1/bootparameters"
        req = request.Request(url=url, data=body, method="PUT", headers={"Content-Type": "application/json"})

        last_error: Exception | None = None
        for _ in range(30):
            try:
                with request.urlopen(req, timeout=5):  # nosec: B310
                    return
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                time.sleep(2)

        raise RuntimeError(f"failed to register default boot params: {last_error}")

    def run_post_deploy_flow(self, config: DeployConfig, host_ip: str, orchestrator: str, dry_run: bool) -> None:
        if dry_run:
            return

        if config.discovery_method == DiscoveryMethod.MAGELLAN:
            self._run_magellan(config, host_ip, orchestrator, dry_run)
        elif config.nodes_file is not None:
            self._register_nodes_file(config, host_ip, orchestrator, dry_run)

        if config.num_vms <= 0:
            return
        if self._is_macos:
            return

        if config.discovery_method == DiscoveryMethod.MAGELLAN:
            for i in range(config.num_vms):
                self._runner(["sudo", str(self.project_root / "scripts" / "create_vm.sh"), "--name", f"virtual-compute-node-{i}"], dry_run=dry_run)
            self._run_magellan(config, host_ip, orchestrator, dry_run)
            return

        current_ip_octet = 50
        for i in range(config.num_vms):
            vm_name = f"virtual-compute-node-{i}"
            component_id = f"x0c0s{i}b0n0"
            static_ip = f"192.168.100.{current_ip_octet}"
            self._runner(["sudo", str(self.project_root / "scripts" / "create_vm.sh"), "--name", vm_name], dry_run=dry_run)
            self._runner(
                [
                    str(self.project_root / "scripts" / "register_local_vm.sh"),
                    vm_name,
                    static_ip,
                    component_id,
                    str(i + 1),
                ],
                env={"ORCHESTRATOR": orchestrator, "HOST_IP": host_ip},
                dry_run=dry_run,
                check=False,
            )
            self._runner(["sudo", "virsh", "destroy", vm_name], dry_run=dry_run, check=False)
            self._runner(["sudo", "virsh", "start", vm_name], dry_run=dry_run, check=False)
            current_ip_octet += 1

    def _register_nodes_file(self, config: DeployConfig, host_ip: str, orchestrator: str, dry_run: bool) -> None:
        if config.nodes_file is None:
            return
        with config.nodes_file.open("r", encoding="utf-8") as handle:
            reader = csv.reader(handle)
            for row in reader:
                if not row:
                    continue
                if row[0].strip().startswith("#"):
                    continue
                if len(row) < 7:
                    raise RuntimeError("nodes file rows must have 7 columns")
                mac, ip, component_id, nid, bmc_ip, bmc_user, bmc_pass = [item.strip() for item in row[:7]]
                validate_mac(mac, "nodes_file.mac")
                validate_ip(ip, "nodes_file.ip")
                validate_ip(bmc_ip, "nodes_file.bmc_ip")
                self._runner(
                    [
                        str(self.project_root / "scripts" / "register_hardware_node.sh"),
                        mac,
                        ip,
                        component_id,
                        nid,
                        bmc_ip,
                        bmc_user,
                        bmc_pass,
                    ],
                    env={"ORCHESTRATOR": orchestrator, "HOST_IP": host_ip},
                    dry_run=dry_run,
                )

    def _run_magellan(self, config: DeployConfig, host_ip: str, orchestrator: str, dry_run: bool) -> None:
        common_sh = self.project_root / "scripts" / "common.sh"
        env_assign = [
            f"ORCHESTRATOR='{orchestrator}'",
            f"MAGELLAN_SUBNETS='{config.magellan_subnets}'",
            f"MAGELLAN_HOSTS='{config.magellan_hosts}'",
            f"MAGELLAN_SUBNET_MASK='{config.magellan_subnet_mask}'",
            f"MAGELLAN_BMC_USER='{config.magellan_bmc_user}'",
            f"MAGELLAN_BMC_PASS='{config.magellan_bmc_pass}'",
            f"MAGELLAN_BMC_ID_MAP='{config.magellan_bmc_id_map}'",
            f"MAGELLAN_CACHE='{config.magellan_cache}'",
            f"MAGELLAN_INSECURE='{'true' if config.magellan_insecure else 'false'}'",
        ]
        command = " ".join(env_assign) + f" bash -lc \"source '{common_sh}' && run_magellan_discovery '{host_ip}'\""
        self._runner(["bash", "-lc", command], dry_run=dry_run)

    def _wait_for_url(self, url: str, label: str, max_attempts: int = 60, interval_seconds: int = 2) -> None:
        last_error: Exception | None = None
        for _ in range(max_attempts):
            try:
                with request.urlopen(url, timeout=5):  # nosec: B310
                    return
            except (error.URLError, TimeoutError) as exc:
                last_error = exc
                time.sleep(interval_seconds)
        raise RuntimeError(f"{label} did not become ready: {last_error}")
