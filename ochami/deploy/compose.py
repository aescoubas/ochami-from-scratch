from __future__ import annotations

from pathlib import Path
from typing import Callable

from ochami.build import BuildManager
from ochami.config import DeployConfig, DeploymentMethod
from ochami.defaults import DEFAULT_DATABASES, DEFAULT_PORTS, ensure_runtime_secrets, resolve_host_port
from ochami.deploy.base import LOCALHOST_HEALTH_CHECKS, BaseDeployer
from ochami.network import NetworkManager
from ochami.prerequisites import PrerequisitesInstaller
from ochami.registry import RegistryManager
from ochami.templates import TemplateRenderer
from ochami.utils import is_macos, run, run_output, write_env_file


class ComposeDeployer(BaseDeployer):
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
        macos: bool | None = None,
    ) -> None:
        self.project_root = project_root or Path(__file__).resolve().parents[2]
        self.compose_dir = self.project_root / "ochami-docker-compose"
        self._run = runner
        self._is_macos = is_macos() if macos is None else macos
        self.renderer = renderer or TemplateRenderer(self.project_root / "templates")
        self.network = network or NetworkManager(self.project_root, runner=runner, output_runner=output_runner, macos=self._is_macos)
        self.registry = registry or RegistryManager(self.project_root, runner=runner, macos=self._is_macos)
        self.builder = builder or BuildManager(self.project_root, runner=runner, output_runner=output_runner)
        self.prerequisites = prerequisites or PrerequisitesInstaller(
            runner=runner,
            output_runner=output_runner,
            macos=self._is_macos,
        )
        self.secrets_provider = secrets_provider or (lambda: ensure_runtime_secrets(self.project_root))
        self.postgres_port_resolver = postgres_port_resolver or resolve_host_port

    def validate(self, config: DeployConfig) -> None:
        super().validate(config)
        if config.method != DeploymentMethod.DOCKER_COMPOSE:
            raise ValueError("ComposeDeployer only supports --method docker-compose")
        if not (self.compose_dir / "docker-compose.yml").is_file():
            raise ValueError(f"missing compose file: {self.compose_dir / 'docker-compose.yml'}")

    def configure_network(self, config: DeployConfig, dry_run: bool) -> str:
        return self.network.configure_for_compose(config, dry_run=dry_run)

    def _method_label(self) -> str:
        return "docker-compose"

    def deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        with self.console.phase("Installing prerequisites..."):
            self._install_prerequisites(config, dry_run=dry_run)

        with self.console.phase("Building images..."):
            self._build_images(config, dry_run=dry_run)

        runtime = self._build_runtime_values(config=config, host_ip=host_ip)

        if not dry_run:
            self._generate_env_file(config=config, runtime=runtime)
            self._render_compose_configs(runtime=runtime)

        with self.console.phase("Starting services..."):
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
        service_names = ", ".join(name for name, _ in LOCALHOST_HEALTH_CHECKS)
        with self.console.phase("Waiting for services...") as ctx:
            self.registry.wait_for_services(LOCALHOST_HEALTH_CHECKS, dry_run=dry_run)
            ctx.set_detail(service_names)

        with self.console.phase("Registering boot defaults..."):
            self.registry.register_bss_defaults(
                host="localhost",
                host_ip=host_ip,
                extra_params=f"ds=nocloud-net;s=http://{host_ip}:80/cloud-init/",
                dry_run=dry_run,
            )
            self.registry.run_post_deploy_flow(config, host_ip=host_ip, orchestrator="docker-compose", dry_run=dry_run)

        with self.console.phase("Writing MCP defaults..."):
            self.write_mcp_defaults(host_ip=host_ip, http_port=DEFAULT_PORTS["HTTP_PORT"], method_label="docker-compose", dry_run=dry_run)

    def ensure_healthy(self, config: DeployConfig, dry_run: bool = False) -> None:
        compose_cmd = self._compose_command()
        self._run(
            [*compose_cmd, "-p", "ochami", "ps", "--filter", "status=running"],
            dry_run=dry_run,
        )

    def _install_prerequisites(self, config: DeployConfig, dry_run: bool) -> None:
        self.prerequisites.install(set_fs_protected_regular=config.set_fs_protected_regular, dry_run=dry_run)

    def _build_images(self, config: DeployConfig, dry_run: bool) -> None:
        self.builder.build_images_if_needed(
            config,
            orchestrator="docker-compose",
            container_tool="docker",
            force_rebuild=config.rebuild,
            dry_run=dry_run,
        )

    def _build_runtime_values(self, config: DeployConfig, host_ip: str) -> dict[str, str]:
        secrets_map = self.secrets_provider()
        runtime: dict[str, str] = {}
        runtime.update(DEFAULT_PORTS)
        runtime.update(DEFAULT_DATABASES)
        runtime.update(secrets_map)
        postgres_port = self.postgres_port_resolver(int(DEFAULT_PORTS["POSTGRES_PORT"]))
        runtime["POSTGRES_PORT"] = str(postgres_port)

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

        self.renderer.render_to_file("shared/kea-dhcp4.conf.j2", configs_dir / "kea-dhcp4.conf", context)
        self.renderer.render_to_file("shared/boot.ipxe.j2", configs_dir / "boot.ipxe", context)
        self.renderer.render_to_file("shared/stork-server.env.j2", configs_dir / "stork-server.env", context)
        self.renderer.render_to_file("shared/nginx-default.conf.j2", configs_dir / "nginx-default.conf", context)

    def _compose_command(self) -> list[str]:
        # Keep the same command preference as existing scripts.
        return ["docker", "compose"]



