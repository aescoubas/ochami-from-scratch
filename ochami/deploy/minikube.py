from __future__ import annotations

import json
from pathlib import Path
import tempfile
import time
from typing import Callable

from ochami.build import BuildManager
from ochami.config import DeployConfig, DeploymentMethod
from ochami.defaults import DEFAULT_DATABASES, HTTP_PORT, MCP_PROXY_PORT, ensure_runtime_secrets
from ochami.deploy.base import BaseDeployer
from ochami.network import NetworkManager
from ochami.prerequisites import PrerequisitesInstaller
from ochami.registry import RegistryManager
from ochami.system import (
    FS_PROTECTED_REGULAR_STATE_FILE,
    lower_fs_protected_regular_if_needed,
    relax_permissions,
)
from ochami.utils import is_macos, run, run_output


class MinikubeDeployer(BaseDeployer):
    def __init__(
        self,
        *,
        project_root: Path | None = None,
        runner=run,
        output_runner=run_output,
        network: NetworkManager | None = None,
        registry: RegistryManager | None = None,
        builder: BuildManager | None = None,
        prerequisites: PrerequisitesInstaller | None = None,
        secrets_provider: Callable[[], dict[str, str]] | None = None,
        sleeper: Callable[[float], None] = time.sleep,
        macos: bool | None = None,
        home_dir: Path | None = None,
        fs_state_path: Path = FS_PROTECTED_REGULAR_STATE_FILE,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self._run = runner
        self._run_output = output_runner
        self._sleep = sleeper
        self._is_macos = is_macos() if macos is None else macos

        self.helm_dir = self.project_root / "ochami-helm"
        self.values_base_file = self.helm_dir / "values-pxe.yaml"
        self._active_interface = "virbr-pxe"
        self.home_dir = home_dir or Path.home()
        self._fs_state_path = fs_state_path

        self.network = network or NetworkManager(self.project_root, runner=runner, output_runner=output_runner, macos=self._is_macos)
        self.registry = registry or RegistryManager(self.project_root, runner=runner, macos=self._is_macos)
        self.builder = builder or BuildManager(self.project_root, runner=runner, output_runner=output_runner)
        self.prerequisites = prerequisites or PrerequisitesInstaller(
            runner=runner,
            output_runner=output_runner,
            macos=self._is_macos,
        )
        self.secrets_provider = secrets_provider or (lambda: ensure_runtime_secrets(self.project_root))

    def validate(self, config: DeployConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.MINIKUBE:
            raise ValueError("MinikubeDeployer only supports --method minikube")
        if not self.helm_dir.is_dir():
            raise ValueError(f"missing helm directory: {self.helm_dir}")
        if not self.values_base_file.is_file():
            raise ValueError(f"missing values file: {self.values_base_file}")

    def configure_network(self, config: DeployConfig, dry_run: bool) -> str:
        host_ip, active_interface = self.network.configure_for_minikube(config, dry_run=dry_run)
        self._active_interface = active_interface
        return host_ip

    def _method_label(self) -> str:
        return "minikube"

    def _mcp_port(self) -> int | str:
        return MCP_PROXY_PORT

    def deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        with self.console.phase("Installing prerequisites..."):
            self._install_prerequisites(config=config, dry_run=dry_run)

        with self.console.phase("Starting minikube..."):
            self._ensure_minikube_running(dry_run=dry_run)

        with self.console.phase("Building images..."):
            self._build_images(config=config, dry_run=dry_run)

        runtime = self._build_runtime_values(config=config, host_ip=host_ip)
        values_content = self._build_values_file_content(config, runtime)
        values_file: Path | None = None

        with self.console.phase("Deploying Helm chart..."):
            try:
                if not dry_run:
                    tmp = tempfile.NamedTemporaryFile(mode="w", delete=False, encoding="utf-8", suffix=".yaml")
                    tmp.write(values_content)
                    tmp.flush()
                    tmp.close()
                    values_file = Path(tmp.name)
                else:
                    values_file = self.project_root / ".tmp-minikube-values.yaml"

                self._run(["minikube", "kubectl", "--", "create", "ns", "ochami"], dry_run=dry_run, check=False)
                self._wait_for_service_account(dry_run=dry_run)
                self._restart_openchami_pods(config=config, dry_run=dry_run)

                self._run(
                    [
                        "helm",
                        "upgrade",
                        "--install",
                        "ochami",
                        str(self.helm_dir),
                        "-n",
                        "ochami",
                        "-f",
                        str(self.values_base_file),
                        "-f",
                        str(values_file),
                        "--wait",
                        "--timeout",
                        "10m0s",
                    ],
                    dry_run=dry_run,
                )
            finally:
                if values_file is not None and values_file.exists() and not dry_run:
                    values_file.unlink()

    def post_deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        with self.console.phase("Registering boot defaults..."):
            bss_ip = self._discover_service_cluster_ip("ochami-bss", dry_run=dry_run)
            self.registry.register_bss_defaults(
                host=bss_ip,
                host_ip=host_ip,
                extra_params=f"ds=nocloud-net;s=http://{host_ip}:{HTTP_PORT}/cloud-init/",
                dry_run=dry_run,
            )
            self.registry.run_post_deploy_flow(config, host_ip=host_ip, orchestrator="minikube", dry_run=dry_run)

        with self.console.phase("Writing MCP defaults..."):
            self.write_mcp_defaults(host_ip=host_ip, http_port=MCP_PROXY_PORT, method_label="minikube", dry_run=dry_run)

    def ensure_healthy(self, config: DeployConfig, dry_run: bool = False) -> None:
        self._run(["minikube", "status"], dry_run=dry_run)
        self._run(
            ["minikube", "kubectl", "--", "get", "pods", "-n", "ochami"],
            dry_run=dry_run,
        )

    def _install_prerequisites(self, config: DeployConfig, dry_run: bool) -> None:
        self.prerequisites.install(set_fs_protected_regular=config.set_fs_protected_regular, dry_run=dry_run)

    def _ensure_minikube_running(self, dry_run: bool) -> None:
        status_rc = self._run(["minikube", "status"], dry_run=dry_run, check=False)
        if status_rc == 0:
            return

        start_cmd = [
            "minikube",
            "start",
            "--driver=docker" if self._is_macos else "--driver=none",
            "--memory=4096",
            "--cpus=2",
        ]
        if self._is_macos:
            self._run(start_cmd, dry_run=dry_run)
            return

        try:
            self._run(["sudo", "-E", *start_cmd], dry_run=dry_run)
        except RuntimeError as exc:
            if not self._retry_minikube_start_with_fs_workaround(exc=exc, start_cmd=start_cmd, dry_run=dry_run):
                raise
        relax_permissions(
            [self.home_dir / ".minikube", self.home_dir / ".kube"],
            runner=self._run,
            dry_run=dry_run,
        )

    def _retry_minikube_start_with_fs_workaround(
        self,
        *,
        exc: RuntimeError,
        start_cmd: list[str],
        dry_run: bool,
    ) -> bool:
        if "command failed (37):" not in str(exc):
            return False

        lowered = lower_fs_protected_regular_if_needed(
            runner=self._run,
            output_runner=self._run_output,
            fs_state_path=self._fs_state_path,
            dry_run=dry_run,
            macos=self._is_macos,
        )
        if not lowered:
            return False

        self._run(["sudo", "-E", *start_cmd], dry_run=dry_run)
        return True

    def _build_images(self, config: DeployConfig, dry_run: bool) -> None:
        self.builder.build_images_if_needed(
            config,
            orchestrator="minikube",
            container_tool="docker",
            force_rebuild=config.rebuild,
            dry_run=dry_run,
        )

    def _build_runtime_values(self, config: DeployConfig, host_ip: str) -> dict[str, str]:
        runtime: dict[str, str] = {}
        runtime.update(DEFAULT_DATABASES)
        runtime.update(self.secrets_provider())
        runtime.update(
            {
                "HOST_IP": host_ip,
                "PXE_INTERFACE": self._active_interface or config.pxe_interface,
                "DHCP_START": config.dhcp_start,
                "DHCP_END": config.dhcp_end,
                "DHCP_NETMASK": config.dhcp_netmask,
                "PXE_CIDR": str(config.pxe_cidr),
                "NUM_VMS": str(config.num_vms),
                "PROJECT_ROOT": str(self.project_root),
            }
        )
        return runtime

    def _build_values_file_content(self, config: DeployConfig, runtime: dict[str, str]) -> str:
        values: dict[str, object] = {
            "externalIp": runtime["HOST_IP"],
            "pxeInterface": runtime["PXE_INTERFACE"],
            "tftpServerIp": runtime["HOST_IP"],
            "dhcpStart": runtime["DHCP_START"],
            "dhcpEnd": runtime["DHCP_END"],
            "dhcpNetmask": runtime["DHCP_NETMASK"],
            "dhcpCidr": runtime["PXE_CIDR"],
            "projectRoot": runtime["PROJECT_ROOT"],
            "httpServer": {"hostNetwork": True, "port": HTTP_PORT},
            "postgres": {
                "user": runtime["POSTGRES_USER"],
                "password": runtime["POSTGRES_PASSWORD"],
                "smd_password": runtime["SMD_DB_PASSWORD"],
                "bss_password": runtime["BSS_DB_PASSWORD"],
                "hydra_password": runtime["HYDRA_DB_PASSWORD"],
                "kea_password": runtime["KEA_DB_PASSWORD"],
                "pcs_password": runtime["PCS_DB_PASSWORD"],
                "stork_password": runtime["STORK_DB_PASSWORD"],
            },
            "bss": {
                "ipxe": {"server": runtime["HOST_IP"]},
                "advertise_address": runtime["HOST_IP"],
                "nfdUrl": f"http://{runtime['HOST_IP']}/hmi/v1/subscribe",
            },
            "kea": {
                "db": {
                    "host": "ochami-postgres",
                    "port": 5432,
                    "name": runtime["KEA_DB_NAME"],
                    "user": runtime["KEA_DB_USER"],
                    "password": runtime["KEA_DB_PASSWORD"],
                }
            },
            "bootScriptUrl": f"http://{runtime['HOST_IP']}/boot/v1/bootscript?mac=${{mac}}",
            "stork": {"enabled": config.enable_stork},
        }
        num_vms = int(runtime["NUM_VMS"])
        if num_vms > 0:
            values["emulator"] = {"enabled": True, "replicas": num_vms}
            if self._is_macos:
                values["emulator"]["libvirtSocket"] = {"enabled": False}
        return json.dumps(values, indent=2) + "\n"

    def _wait_for_service_account(self, dry_run: bool) -> None:
        if dry_run:
            return
        for _ in range(30):
            rc = self._run(
                ["minikube", "kubectl", "--", "get", "sa", "default", "-n", "ochami"],
                dry_run=dry_run,
                check=False,
            )
            if rc == 0:
                return
            self._sleep(1)
        raise RuntimeError("default service account in namespace ochami was not ready in time")

    def _restart_openchami_pods(self, config: DeployConfig, dry_run: bool) -> None:
        components = [
            "http-server",
            "tftp",
            "kea",
            "postgres",
            "smd",
            "bss",
            "cloud-init",
            "pcs",
        ]
        if config.enable_stork:
            components.append("stork-server")
        for component in components:
            self._run(
                [
                    "minikube",
                    "kubectl",
                    "--",
                    "delete",
                    "pod",
                    "-n",
                    "ochami",
                    "-l",
                    f"app.kubernetes.io/component={component}",
                    "--wait=false",
                ],
                dry_run=dry_run,
                check=False,
            )

    def _discover_service_cluster_ip(self, service: str, dry_run: bool) -> str:
        if dry_run:
            return "127.0.0.1"
        command = [
            "minikube",
            "kubectl",
            "--",
            "get",
            "svc",
            service,
            "-n",
            "ochami",
            "-o",
            "jsonpath={.spec.clusterIP}",
        ]
        for _ in range(30):
            result = self._run_output(command, dry_run=False, check=False).strip()
            if result:
                return result
            self._sleep(2)
        raise RuntimeError(f"failed to determine ClusterIP for service {service}")

