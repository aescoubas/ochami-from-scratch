from __future__ import annotations

import os
from pathlib import Path
import tempfile
from typing import Callable

from ochami.build import BuildManager
from ochami.config import DeployConfig, DeploymentMethod
from ochami.deploy.base import BaseDeployer
from ochami.deploy.compose import DEFAULT_DATABASES, DEFAULT_PORTS, ensure_runtime_secrets, resolve_host_port
from ochami.network import NetworkManager
from ochami.prerequisites import PrerequisitesInstaller
from ochami.registry import RegistryManager
from ochami.templates import TemplateRenderer
from ochami.utils import is_macos, run, run_output, substitute_env_vars


class QuadletsDeployer(BaseDeployer):
    def __init__(
        self,
        *,
        project_root: Path | None = None,
        runner=run,
        output_runner=run_output,
        renderer: TemplateRenderer | None = None,
        network: NetworkManager | None = None,
        registry: RegistryManager | None = None,
        builder: BuildManager | None = None,
        prerequisites: PrerequisitesInstaller | None = None,
        secrets_provider: Callable[[], dict[str, str]] | None = None,
        postgres_port_resolver: Callable[[int], int] | None = None,
        quadlets_install_dir: Path | None = None,
        openchami_config_dir: Path | None = None,
        systemd_dir: Path | None = None,
        linux: bool | None = None,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self._run = runner
        self._linux = (not is_macos()) if linux is None else linux

        self.quadlets_dir = self.project_root / "ochami-quadlets"
        self.quadlets_install_dir = quadlets_install_dir or Path("/etc/containers/systemd")
        self.openchami_config_dir = openchami_config_dir or Path("/etc/openchami")
        self.openchami_configs_dir = self.openchami_config_dir / "configs"
        self.systemd_dir = systemd_dir or Path("/etc/systemd/system")

        self.renderer = renderer or TemplateRenderer(self.project_root / "templates")
        self.network = network or NetworkManager(self.project_root, runner=runner, output_runner=output_runner)
        self.registry = registry or RegistryManager(self.project_root, runner=runner)
        self.builder = builder or BuildManager(self.project_root, runner=runner, output_runner=output_runner)
        self.prerequisites = prerequisites or PrerequisitesInstaller(
            runner=runner,
            output_runner=output_runner,
            macos=not self._linux,
        )
        self.secrets_provider = secrets_provider or (lambda: ensure_runtime_secrets(self.project_root))
        self.postgres_port_resolver = postgres_port_resolver or resolve_host_port

    def validate(self, config: DeployConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.QUADLETS:
            raise ValueError("QuadletsDeployer only supports --method quadlets")
        if not self._linux:
            raise ValueError("quadlets deployment requires Linux/systemd")
        if not self.quadlets_dir.is_dir():
            raise ValueError(f"missing quadlets directory: {self.quadlets_dir}")

    def configure_network(self, config: DeployConfig, dry_run: bool) -> str:
        return self.network.configure_for_quadlets(config, dry_run=dry_run)

    def deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        self._install_prerequisites(config=config, dry_run=dry_run)
        self._build_images(config=config, dry_run=dry_run)
        runtime = self._build_runtime_values(config=config, host_ip=host_ip)

        if not dry_run:
            self._prepare_directories(dry_run=dry_run)
            self._write_env_file(runtime, dry_run=dry_run)
            self._render_configs(runtime, dry_run=dry_run)
            self._install_units(runtime, dry_run=dry_run)
            self._ensure_postgres_init_executable(dry_run=dry_run)

        self._run(["sudo", "systemctl", "daemon-reload"], dry_run=dry_run)
        self._run(["sudo", "systemctl", "enable", "openchami.target"], dry_run=dry_run, check=False)
        self._run(["sudo", "systemctl", "start", "openchami.target"], dry_run=dry_run)

    def post_deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        checks = [
            ("SMD", "http://localhost:27779/hsm/v2/service/ready"),
            ("BSS", "http://localhost:27778/boot/v1/bootparameters"),
            ("cloud-init", "http://localhost:27777/cloud-init/version"),
            ("PCS", "http://localhost:28007/liveness"),
            ("Stork", "http://localhost:28010/api/version"),
        ]
        self.registry.wait_for_services(checks, dry_run=dry_run)
        self.registry.register_bss_defaults(
            host=host_ip,
            host_ip=host_ip,
            extra_params=f"ds=nocloud-net;s=http://{host_ip}:80/cloud-init/",
            dry_run=dry_run,
        )
        self.registry.run_post_deploy_flow(config, host_ip=host_ip, orchestrator="quadlets", dry_run=dry_run)
        self._write_mcp_defaults(host_ip=host_ip, http_port=DEFAULT_PORTS["HTTP_PORT"], dry_run=dry_run)

    def _install_prerequisites(self, config: DeployConfig, dry_run: bool) -> None:
        self.prerequisites.install(set_fs_protected_regular=config.set_fs_protected_regular, dry_run=dry_run)

    def _build_images(self, config: DeployConfig, dry_run: bool) -> None:
        self.builder.build_images_if_needed(
            config,
            orchestrator="quadlets",
            container_tool="sudo podman",
            force_rebuild=config.rebuild,
            dry_run=dry_run,
        )

    def _build_runtime_values(self, config: DeployConfig, host_ip: str) -> dict[str, str]:
        runtime: dict[str, str] = {}
        runtime.update(DEFAULT_PORTS)
        runtime.update(DEFAULT_DATABASES)
        runtime.update(self.secrets_provider())
        runtime["POSTGRES_PORT"] = str(self.postgres_port_resolver(int(DEFAULT_PORTS["POSTGRES_PORT"])))
        runtime.update(
            {
                "HOST_IP": host_ip,
                "PXE_INTERFACE": config.pxe_interface,
                "DHCP_START": config.dhcp_start,
                "DHCP_END": config.dhcp_end,
                "DHCP_NETMASK": config.dhcp_netmask,
                "PXE_CIDR": str(config.pxe_cidr),
                "NUM_VMS": str(config.num_vms),
                "PROJECT_ROOT": str(self.project_root),
            }
        )
        return runtime

    def _prepare_directories(self, *, dry_run: bool) -> None:
        for directory in (self.openchami_configs_dir, self.quadlets_install_dir, self.systemd_dir):
            try:
                directory.mkdir(parents=True, exist_ok=True)
            except PermissionError:
                self._run(["sudo", "mkdir", "-p", str(directory)], dry_run=dry_run)

    def _write_env_file(self, runtime: dict[str, str], *, dry_run: bool) -> None:
        postgres_multiple = (
            f"{runtime['SMD_DB_NAME']}:{runtime['SMD_DB_USER']}:{runtime['SMD_DB_PASSWORD']},"
            f"{runtime['BSS_DB_NAME']}:{runtime['BSS_DB_USER']}:{runtime['BSS_DB_PASSWORD']},"
            f"{runtime['KEA_DB_NAME']}:{runtime['KEA_DB_USER']}:{runtime['KEA_DB_PASSWORD']},"
            f"{runtime['PCS_DB_NAME']}:{runtime['PCS_DB_USER']}:{runtime['PCS_DB_PASSWORD']},"
            f"{runtime['STORK_DB_NAME']}:{runtime['STORK_DB_USER']}:{runtime['STORK_DB_PASSWORD']}"
        )
        lines = [
            "# OpenCHAMI Environment Configuration (auto-generated by deploy script)",
            "",
            "# Network",
            f"HOST_IP={runtime['HOST_IP']}",
            f"PXE_INTERFACE={runtime['PXE_INTERFACE']}",
            f"PXE_CIDR={runtime['PXE_CIDR']}",
            f"DHCP_START={runtime['DHCP_START']}",
            f"DHCP_END={runtime['DHCP_END']}",
            f"DHCP_NETMASK={runtime['DHCP_NETMASK']}",
            "",
            "# Service ports",
            f"HTTP_PORT={runtime['HTTP_PORT']}",
            f"SMD_PORT={runtime['SMD_PORT']}",
            f"BSS_PORT={runtime['BSS_PORT']}",
            f"POSTGRES_PORT={runtime['POSTGRES_PORT']}",
            f"CLOUD_INIT_PORT={runtime['CLOUD_INIT_PORT']}",
            f"PCS_PORT={runtime['PCS_PORT']}",
            f"STORK_PORT={runtime['STORK_PORT']}",
            f"STORK_AGENT_PORT={runtime['STORK_AGENT_PORT']}",
            "",
            "# PostgreSQL",
            f"POSTGRES_USER={runtime['POSTGRES_USER']}",
            f"POSTGRES_PASSWORD={runtime['POSTGRES_PASSWORD']}",
            f"POSTGRES_MULTIPLE_DATABASES={postgres_multiple}",
            "",
            "# SMD Database",
            f"SMD_DBPORT={runtime['POSTGRES_PORT']}",
            f"SMD_DBNAME={runtime['SMD_DB_NAME']}",
            f"SMD_DBUSER={runtime['SMD_DB_USER']}",
            f"SMD_DBPASS={runtime['SMD_DB_PASSWORD']}",
            "SMD_DBOPTS=sslmode=disable",
            "",
            "# BSS Database",
            f"BSS_DBPORT={runtime['POSTGRES_PORT']}",
            f"BSS_DBNAME={runtime['BSS_DB_NAME']}",
            f"BSS_DBUSER={runtime['BSS_DB_USER']}",
            f"BSS_DBPASS={runtime['BSS_DB_PASSWORD']}",
            "BSS_DBOPTS=sslmode=disable",
            f"HSM_URL=http://localhost:{runtime['HTTP_PORT']}",
            f"BSS_IPXE_SERVER={runtime['HOST_IP']}",
            f"BSS_ADVERTISE_ADDRESS={runtime['HOST_IP']}",
            f"NFD_URL=http://{runtime['HOST_IP']}:{runtime['HTTP_PORT']}/hmi/v1/subscribe",
            "SMS_SERVER=http://localhost:${HTTP_PORT}",
            "",
            "# Kea Database",
            f"KEA_DB_NAME={runtime['KEA_DB_NAME']}",
            f"KEA_DB_USER={runtime['KEA_DB_USER']}",
            f"KEA_DB_PASSWORD={runtime['KEA_DB_PASSWORD']}",
            "",
            "# PCS Database",
            f"PCS_DB_NAME={runtime['PCS_DB_NAME']}",
            f"PCS_DB_USER={runtime['PCS_DB_USER']}",
            f"PCS_DB_PASSWORD={runtime['PCS_DB_PASSWORD']}",
            "",
            "# Stork",
            f"STORK_DB_NAME={runtime['STORK_DB_NAME']}",
            f"STORK_DB_USER={runtime['STORK_DB_USER']}",
            f"STORK_DB_PASSWORD={runtime['STORK_DB_PASSWORD']}",
            "STORK_AGENT_SERVER_URL=http://localhost:${HTTP_PORT}",
            f"STORK_AGENT_HOST={runtime['HOST_IP']}",
            f"STORK_AGENT_PORT={runtime['STORK_AGENT_PORT']}",
            "",
            "# Kea sidecar",
            f"DB_NAME={runtime['KEA_DB_NAME']}",
            f"DB_USER={runtime['KEA_DB_USER']}",
            f"DB_PASS={runtime['KEA_DB_PASSWORD']}",
            f"DB_PORT={runtime['POSTGRES_PORT']}",
            "",
        ]
        self._write_text_file(self.openchami_config_dir / "openchami.env", "\n".join(lines), dry_run=dry_run)

    def _render_configs(self, runtime: dict[str, str], *, dry_run: bool) -> None:
        source_dir = self.quadlets_dir / "configs"
        for path in source_dir.iterdir():
            if path.name.endswith(".template"):
                destination = self.openchami_configs_dir / path.name.removesuffix(".template")
                rendered = substitute_env_vars(path.read_text(encoding="utf-8"), runtime)
                self._write_text_file(destination, rendered, dry_run=dry_run)
            elif path.suffix in {".sh", ".py", ".conf", ".html"} or path.name in {"user-data", "meta-data"}:
                destination = self.openchami_configs_dir / path.name
                self._write_bytes_file(destination, path.read_bytes(), dry_run=dry_run)

        context = {
            "http_port": runtime["HTTP_PORT"],
            "smd_port": runtime["SMD_PORT"],
            "bss_port": runtime["BSS_PORT"],
            "cloud_init_port": runtime["CLOUD_INIT_PORT"],
            "pcs_port": runtime["PCS_PORT"],
            "stork_port": runtime["STORK_PORT"],
        }
        rendered_nginx = self.renderer.render("nginx-default.conf.j2", context)
        self._write_text_file(self.openchami_configs_dir / "nginx-default.conf", rendered_nginx, dry_run=dry_run)

    def _install_units(self, runtime: dict[str, str], *, dry_run: bool) -> None:
        containers_dir = self.quadlets_dir / "containers"
        for path in sorted(containers_dir.glob("*.container")):
            rendered = substitute_env_vars(path.read_text(encoding="utf-8"), runtime)
            self._write_text_file(self.quadlets_install_dir / path.name, rendered, dry_run=dry_run)
        for path in sorted(containers_dir.glob("*.target")):
            self._write_bytes_file(self.systemd_dir / path.name, path.read_bytes(), dry_run=dry_run)

        count = int(runtime["NUM_VMS"])
        if count > 0:
            for idx in range(count):
                emulator_text = (
                    "[Unit]\n"
                    f"Description=OpenCHAMI Redfish Emulator (VM {idx})\n\n"
                    "[Container]\n"
                    "Image=localhost/redfish-emulator:latest\n"
                    "Network=host\n"
                    f"Environment=VM_INDEX={idx}\n"
                    "Exec=python -u -c \"import os; idx=os.environ.get('VM_INDEX','0'); script=open('/emulator.py').read(); script=script.replace('INDEX = int(HOSTNAME.split(\\\"-\\\")[-1])', f'INDEX = {idx}'); exec(script)\"\n"
                    "Volume=/var/run/libvirt/libvirt-sock:/var/run/libvirt/libvirt-sock\n\n"
                    "[Service]\n"
                    "Restart=on-failure\n"
                    "TimeoutStartSec=60\n\n"
                    "[Install]\n"
                    "WantedBy=openchami.target\n"
                )
                self._write_text_file(
                    self.quadlets_install_dir / f"redfish-emulator-{idx}.container",
                    emulator_text,
                    dry_run=dry_run,
                )

    def _ensure_postgres_init_executable(self, *, dry_run: bool) -> None:
        path = self.openchami_configs_dir / "postgres-init-db.sh"
        if path.exists():
            try:
                path.chmod(path.stat().st_mode | 0o111)
            except PermissionError:
                self._run(["sudo", "chmod", "a+x", str(path)], dry_run=dry_run, check=False)

    def _write_text_file(self, path: Path, content: str, *, dry_run: bool) -> None:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            return
        except PermissionError:
            self._install_file(path, content.encode("utf-8"), mode="0644", dry_run=dry_run)

    def _write_bytes_file(self, path: Path, content: bytes, *, dry_run: bool) -> None:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            return
        except PermissionError:
            self._install_file(path, content, mode="0644", dry_run=dry_run)

    def _write_mcp_defaults(self, host_ip: str, http_port: str, dry_run: bool) -> None:
        if dry_run:
            return
        path = self.project_root / ".openchami-mcp.env"
        path.write_text(
            (
                "# Generated by ochamifs deploy --method quadlets\n"
                "# OpenCHAMI MCP defaults (quadlets host reverse proxy)\n"
                f"OPENCHAMI_BASE_URL=http://{host_ip}:{http_port}\n"
                "OPENCHAMI_MCP_MODE=read-only\n"
                "# Set to true only when you explicitly want mutating operations.\n"
                "OPENCHAMI_MCP_ENABLE_WRITES=false\n"
            ),
            encoding="utf-8",
        )

    def _install_file(self, destination: Path, content: bytes, *, mode: str, dry_run: bool) -> None:
        with tempfile.NamedTemporaryFile(delete=False) as tmp:
            tmp.write(content)
            tmp_path = Path(tmp.name)
        try:
            self._run(
                ["sudo", "install", "-D", "-m", mode, str(tmp_path), str(destination)],
                dry_run=dry_run,
            )
        finally:
            tmp_path.unlink(missing_ok=True)
