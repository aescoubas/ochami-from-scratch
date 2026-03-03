from __future__ import annotations

import secrets
from pathlib import Path
from typing import Callable

from ochami.config import DeployConfig, DeployMode, DeploymentMethod
from ochami.deploy.base import BaseDeployer
from ochami.network import NetworkManager
from ochami.registry import RegistryManager
from ochami.templates import TemplateRenderer
from ochami.utils import is_macos, parse_env_file, run, write_env_file


DEFAULT_PORTS = {
    "SMD_PORT": "27779",
    "BSS_PORT": "27778",
    "POSTGRES_PORT": "5432",
    "HTTP_PORT": "80",
    "CLOUD_INIT_PORT": "27777",
    "PCS_PORT": "28007",
    "STORK_PORT": "28010",
    "STORK_AGENT_PORT": "28011",
}

DEFAULT_DATABASES = {
    "POSTGRES_USER": "ochami",
    "SMD_DB_NAME": "hmsds",
    "SMD_DB_USER": "smd-user",
    "BSS_DB_NAME": "bssdb",
    "BSS_DB_USER": "bss-user",
    "KEA_DB_NAME": "kea",
    "KEA_DB_USER": "kea-user",
    "PCS_DB_NAME": "pcsdb",
    "PCS_DB_USER": "pcs-user",
    "STORK_DB_NAME": "stork",
    "STORK_DB_USER": "stork-user",
}

SECRET_KEYS = [
    "POSTGRES_PASSWORD",
    "SMD_DB_PASSWORD",
    "BSS_DB_PASSWORD",
    "KEA_DB_PASSWORD",
    "PCS_DB_PASSWORD",
    "STORK_DB_PASSWORD",
    "HYDRA_DB_PASSWORD",
]


class ComposeDeployer(BaseDeployer):
    def __init__(
        self,
        *,
        project_root: Path | None = None,
        runner=run,
        renderer: TemplateRenderer | None = None,
        network: NetworkManager | None = None,
        registry: RegistryManager | None = None,
        secrets_provider: Callable[[], dict[str, str]] | None = None,
        macos: bool | None = None,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self.compose_dir = self.project_root / "ochami-docker-compose"
        self._run = runner
        self._is_macos = is_macos() if macos is None else macos
        self.renderer = renderer or TemplateRenderer(self.project_root / "templates")
        self.network = network or NetworkManager(self.project_root, runner=runner, macos=self._is_macos)
        self.registry = registry or RegistryManager(self.project_root, runner=runner, macos=self._is_macos)
        self.secrets_provider = secrets_provider or (lambda: ensure_runtime_secrets(self.project_root))

    def validate(self, config: DeployConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.DOCKER_COMPOSE:
            raise ValueError("ComposeDeployer only supports --method docker-compose")
        if not (self.compose_dir / "docker-compose.yml").is_file():
            raise ValueError(f"missing compose file: {self.compose_dir / 'docker-compose.yml'}")

    def configure_network(self, config: DeployConfig, dry_run: bool) -> str:
        return self.network.configure_for_compose(config, dry_run=dry_run)

    def deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        self._install_prerequisites(config, dry_run=dry_run)
        self._build_images(config, dry_run=dry_run)

        runtime = self._build_runtime_values(config=config, host_ip=host_ip)

        if not dry_run:
            self._generate_env_file(config=config, runtime=runtime)
            self._render_compose_configs(runtime=runtime)

        compose_cmd = self._compose_command()
        files = [self.compose_dir / "docker-compose.yml"]
        if self._is_macos and (self.compose_dir / "docker-compose.macos.yml").is_file():
            files.append(self.compose_dir / "docker-compose.macos.yml")

        command: list[str] = [*compose_cmd, "-p", "ochami"]
        for file_path in files:
            command.extend(["-f", str(file_path)])
        command.extend(["--env-file", str(self.compose_dir / ".env")])
        if config.num_vms > 0:
            command.extend(["--profile", "emulator"])
        command.extend(["up", "-d", "--wait"])
        self._run(command, dry_run=dry_run)

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
            host="localhost",
            host_ip=host_ip,
            extra_params=f"ds=nocloud-net;s=http://{host_ip}:80/cloud-init/",
            dry_run=dry_run,
        )
        self.registry.run_post_deploy_flow(config, host_ip=host_ip, orchestrator="docker-compose", dry_run=dry_run)

    def _install_prerequisites(self, config: DeployConfig, dry_run: bool) -> None:
        cmd = [str(self.project_root / "scripts" / "install_prerequisites.sh")]
        if config.set_fs_protected_regular:
            cmd.append("--set-fs-protected-regular")
        self._run(cmd, dry_run=dry_run)

    def _build_images(self, config: DeployConfig, dry_run: bool) -> None:
        common_sh = self.project_root / "scripts" / "common.sh"
        command = (
            f"source '{common_sh}' && "
            f"build_images_if_needed 'docker' 'docker-compose' '{'true' if config.rebuild else 'false'}'"
        )
        self._run(["bash", "-lc", command], dry_run=dry_run)

    def _build_runtime_values(self, config: DeployConfig, host_ip: str) -> dict[str, str]:
        secrets_map = self.secrets_provider()
        runtime: dict[str, str] = {}
        runtime.update(DEFAULT_PORTS)
        runtime.update(DEFAULT_DATABASES)
        runtime.update(secrets_map)

        runtime.update(
            {
                "HOST_IP": host_ip,
                "PXE_INTERFACE": "*" if self._is_macos else config.pxe_interface,
                "DHCP_START": config.dhcp_start,
                "DHCP_END": config.dhcp_end,
                "DHCP_NETMASK": config.dhcp_netmask,
                "PXE_CIDR": str(config.pxe_cidr),
                "NUM_VMS": str(config.num_vms),
                "PROJECT_ROOT": str(self.project_root),
            }
        )
        return runtime

    def _generate_env_file(self, config: DeployConfig, runtime: dict[str, str]) -> None:
        env_values = {
            "HOST_IP": runtime["HOST_IP"],
            "PXE_INTERFACE": runtime["PXE_INTERFACE"],
            "DHCP_START": runtime["DHCP_START"],
            "DHCP_END": runtime["DHCP_END"],
            "DHCP_NETMASK": runtime["DHCP_NETMASK"],
            "PXE_CIDR": runtime["PXE_CIDR"],
            "HTTP_PORT": runtime["HTTP_PORT"],
            "SMD_PORT": runtime["SMD_PORT"],
            "BSS_PORT": runtime["BSS_PORT"],
            "POSTGRES_PORT": runtime["POSTGRES_PORT"],
            "POSTGRES_USER": runtime["POSTGRES_USER"],
            "POSTGRES_PASSWORD": runtime["POSTGRES_PASSWORD"],
            "SMD_DB_NAME": runtime["SMD_DB_NAME"],
            "SMD_DB_USER": runtime["SMD_DB_USER"],
            "SMD_DB_PASSWORD": runtime["SMD_DB_PASSWORD"],
            "BSS_DB_NAME": runtime["BSS_DB_NAME"],
            "BSS_DB_USER": runtime["BSS_DB_USER"],
            "BSS_DB_PASSWORD": runtime["BSS_DB_PASSWORD"],
            "KEA_DB_NAME": runtime["KEA_DB_NAME"],
            "KEA_DB_USER": runtime["KEA_DB_USER"],
            "KEA_DB_PASSWORD": runtime["KEA_DB_PASSWORD"],
            "HYDRA_DB_PASSWORD": runtime["HYDRA_DB_PASSWORD"],
            "CLOUD_INIT_PORT": runtime["CLOUD_INIT_PORT"],
            "PCS_DB_NAME": runtime["PCS_DB_NAME"],
            "PCS_DB_USER": runtime["PCS_DB_USER"],
            "PCS_DB_PASSWORD": runtime["PCS_DB_PASSWORD"],
            "PCS_PORT": runtime["PCS_PORT"],
            "STORK_DB_NAME": runtime["STORK_DB_NAME"],
            "STORK_DB_USER": runtime["STORK_DB_USER"],
            "STORK_DB_PASSWORD": runtime["STORK_DB_PASSWORD"],
            "STORK_PORT": runtime["STORK_PORT"],
            "STORK_AGENT_PORT": runtime["STORK_AGENT_PORT"],
            "NUM_VMS": runtime["NUM_VMS"],
            "PROJECT_ROOT": runtime["PROJECT_ROOT"],
        }
        write_env_file(self.compose_dir / ".env", env_values)

    def _render_compose_configs(self, runtime: dict[str, str]) -> None:
        configs_dir = self.compose_dir / "configs"
        configs_dir.mkdir(parents=True, exist_ok=True)

        context = {
            "host_ip": runtime["HOST_IP"],
            "pxe_interface": runtime["PXE_INTERFACE"],
            "pxe_cidr": runtime["PXE_CIDR"],
            "dhcp_start": runtime["DHCP_START"],
            "dhcp_end": runtime["DHCP_END"],
            "dhcp_netmask": runtime["DHCP_NETMASK"],
            "http_port": runtime["HTTP_PORT"],
            "smd_port": runtime["SMD_PORT"],
            "bss_port": runtime["BSS_PORT"],
            "postgres_port": runtime["POSTGRES_PORT"],
            "cloud_init_port": runtime["CLOUD_INIT_PORT"],
            "pcs_port": runtime["PCS_PORT"],
            "stork_port": runtime["STORK_PORT"],
            "stork_agent_port": runtime["STORK_AGENT_PORT"],
            "kea_db_name": runtime["KEA_DB_NAME"],
            "kea_db_user": runtime["KEA_DB_USER"],
            "kea_db_password": runtime["KEA_DB_PASSWORD"],
            "stork_db_name": runtime["STORK_DB_NAME"],
            "stork_db_user": runtime["STORK_DB_USER"],
            "stork_db_password": runtime["STORK_DB_PASSWORD"],
            "pcs_db_name": runtime["PCS_DB_NAME"],
            "pcs_db_user": runtime["PCS_DB_USER"],
            "pcs_db_password": runtime["PCS_DB_PASSWORD"],
        }

        self.renderer.render_to_file("compose/kea-dhcp4.conf.j2", configs_dir / "kea-dhcp4.conf", context)
        self.renderer.render_to_file("compose/boot.ipxe.j2", configs_dir / "boot.ipxe", context)
        self.renderer.render_to_file("compose/stork-server.env.j2", configs_dir / "stork-server.env", context)
        self.renderer.render_to_file("nginx-default.conf.j2", configs_dir / "nginx-default.conf", context)

    def _compose_command(self) -> list[str]:
        # Keep the same command preference as existing scripts.
        return ["docker", "compose"]


def ensure_runtime_secrets(project_root: Path) -> dict[str, str]:
    path = project_root / ".openchami-secrets.env"
    values = parse_env_file(path)

    for key in SECRET_KEYS:
        env_override = values.get(key, "")
        if key in values and env_override:
            continue
        values[key] = values.get(key) or secrets.token_hex(24)

    ordered = {key: values[key] for key in SECRET_KEYS}
    write_env_file(path, ordered)
    path.chmod(0o600)
    return ordered
