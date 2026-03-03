from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Annotated

import typer

from ochami.config import (
    DeployConfig,
    DeployMode,
    DeploymentMethod,
    DnsConflictPolicy,
    DiscoveryMethod,
    TeardownConfig,
)
from ochami.deploy.compose import ComposeDeployer
from ochami.teardown.compose import ComposeTeardown

app = typer.Typer(help="OpenCHAMI Python CLI bridge.")

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def run_script(script_name: str, args: list[str], env: dict[str, str], dry_run: bool = False) -> int:
    script_path = PROJECT_ROOT / script_name
    if not script_path.is_file():
        raise typer.BadParameter(f"script not found: {script_path}")

    cmd = ["bash", str(script_path), *args]
    merged_env = os.environ.copy()
    merged_env.update(env)

    if dry_run:
        typer.echo("Dry run enabled; command not executed.")
        typer.echo(f"Command: {' '.join(cmd)}")
        for key in sorted(env):
            typer.echo(f"{key}={env[key]}")
        return 0

    proc = subprocess.run(cmd, env=merged_env, check=False)
    return proc.returncode


def _raise_validation(error: ValueError) -> None:
    raise typer.BadParameter(str(error))


@app.command("deploy")
def deploy(
    method: Annotated[
        DeploymentMethod,
        typer.Option("--method", help="Deployment method"),
    ] = DeploymentMethod.DOCKER_COMPOSE,
    rebuild: Annotated[bool, typer.Option("--rebuild", help="Force rebuild container images")] = False,
    dhcp_start: Annotated[str, typer.Option("--dhcp-start", help="DHCP pool start")] = "192.168.100.100",
    dhcp_end: Annotated[str, typer.Option("--dhcp-end", help="DHCP pool end")] = "192.168.100.200",
    dhcp_netmask: Annotated[str, typer.Option("--dhcp-netmask", help="DHCP netmask")] = "255.255.255.0",
    fail_on_conflict: Annotated[
        bool,
        typer.Option("--fail-on-conflict", help="Fail if UDP/67 is in use"),
    ] = False,
    auto_kill: Annotated[
        bool,
        typer.Option("--auto-kill", help="Terminate conflicting UDP/67 process"),
    ] = False,
    set_fs_protected_regular: Annotated[
        bool,
        typer.Option("--set-fs-protected-regular", help="Set fs.protected_regular=0 during prereq install"),
    ] = False,
    pxe_interface: Annotated[str, typer.Option("--interface", help="PXE interface")] = "virbr-pxe",
    pxe_ip: Annotated[str, typer.Option("--ip", help="Host IP on PXE interface")] = "192.168.100.2",
    pxe_cidr: Annotated[int, typer.Option("--cidr", help="Host CIDR on PXE interface")] = 24,
    phy_iface: Annotated[str, typer.Option("--phy-iface", help="Physical interface to bridge")] = "",
    mode: Annotated[
        DeployMode,
        typer.Option("--mode", help="Deployment mode: libvirt or hardware"),
    ] = DeployMode.LIBVIRT,
    num_vms: Annotated[int, typer.Option("--vms", help="Number of virtual compute nodes")] = 0,
    nodes_file: Annotated[
        Path | None,
        typer.Option("--nodes-file", help="CSV file containing hardware nodes"),
    ] = None,
    smd_ref: Annotated[str, typer.Option("--smd-ref", help="SMD git ref")] = "main",
    bss_ref: Annotated[str, typer.Option("--bss-ref", help="BSS git ref")] = "main",
    pcs_ref: Annotated[str, typer.Option("--pcs-ref", help="PCS git ref")] = "main",
    smd_repo_uri: Annotated[str, typer.Option("--smd-repo-uri", help="SMD repo URI")] = "https://github.com/aescoubas/ochami-smd.git",
    bss_repo_uri: Annotated[str, typer.Option("--bss-repo-uri", help="BSS repo URI")] = "https://github.com/aescoubas/ochami-bss.git",
    pcs_repo_uri: Annotated[str, typer.Option("--pcs-repo-uri", help="PCS repo URI")] = "https://github.com/OpenCHAMI/power-control.git",
    discovery_method: Annotated[
        DiscoveryMethod,
        typer.Option("--discovery-method", help="Discovery method: static or magellan"),
    ] = DiscoveryMethod.STATIC,
    magellan_subnets: Annotated[
        str,
        typer.Option("--magellan-subnets", help="Comma-separated Magellan scan subnets"),
    ] = "",
    magellan_hosts: Annotated[
        str,
        typer.Option("--magellan-hosts", help="Comma-separated Magellan hosts/URIs"),
    ] = "",
    magellan_subnet_mask: Annotated[
        str,
        typer.Option("--magellan-subnet-mask", help="Subnet mask used by Magellan scan"),
    ] = "",
    magellan_bmc_user: Annotated[
        str,
        typer.Option("--magellan-bmc-user", help="BMC username for Magellan collect"),
    ] = "",
    magellan_bmc_pass: Annotated[
        str,
        typer.Option("--magellan-bmc-pass", help="BMC password for Magellan collect"),
    ] = "",
    magellan_bmc_id_map: Annotated[
        str,
        typer.Option("--magellan-bmc-id-map", help="BMC ID map for Magellan collect"),
    ] = "",
    magellan_cache: Annotated[str, typer.Option("--magellan-cache", help="Magellan cache path")] = "",
    magellan_insecure: Annotated[
        bool,
        typer.Option("--magellan-insecure", help="Skip TLS verification for Magellan"),
    ] = False,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Show command/env without execution")] = False,
) -> None:
    if fail_on_conflict and auto_kill:
        raise typer.BadParameter("choose only one of --fail-on-conflict or --auto-kill")

    conflict_policy = DnsConflictPolicy.FAIL
    if auto_kill:
        conflict_policy = DnsConflictPolicy.AUTO_KILL

    try:
        cfg = DeployConfig(
            method=method,
            rebuild=rebuild,
            dhcp_start=dhcp_start,
            dhcp_end=dhcp_end,
            dhcp_netmask=dhcp_netmask,
            dhcp_conflict_policy=conflict_policy,
            set_fs_protected_regular=set_fs_protected_regular,
            pxe_interface=pxe_interface,
            pxe_ip=pxe_ip,
            pxe_cidr=pxe_cidr,
            phy_iface=phy_iface,
            mode=mode,
            num_vms=num_vms,
            nodes_file=nodes_file,
            smd_ref=smd_ref,
            bss_ref=bss_ref,
            pcs_ref=pcs_ref,
            smd_repo_uri=smd_repo_uri,
            bss_repo_uri=bss_repo_uri,
            pcs_repo_uri=pcs_repo_uri,
            discovery_method=discovery_method,
            magellan_subnets=magellan_subnets,
            magellan_hosts=magellan_hosts,
            magellan_subnet_mask=magellan_subnet_mask,
            magellan_bmc_user=magellan_bmc_user,
            magellan_bmc_pass=magellan_bmc_pass,
            magellan_bmc_id_map=magellan_bmc_id_map,
            magellan_cache=magellan_cache,
            magellan_insecure=magellan_insecure,
        )
    except ValueError as exc:
        _raise_validation(exc)

    if cfg.method == DeploymentMethod.DOCKER_COMPOSE:
        ComposeDeployer().run(cfg, dry_run=dry_run)
        return

    exit_code = run_script("deploy.sh", cfg.to_shell_args(), cfg.to_env(), dry_run=dry_run)
    if exit_code != 0:
        raise typer.Exit(code=exit_code)


@app.command("teardown")
def teardown(
    method: Annotated[
        DeploymentMethod,
        typer.Option("--method", help="Teardown method"),
    ] = DeploymentMethod.DOCKER_COMPOSE,
    remove_images: Annotated[bool, typer.Option("--remove-images", help="Also remove container images")] = False,
    vm_name: Annotated[str, typer.Option("--vm-name", help="VM name pattern to delete")] = "virtual-compute-node",
    yes: Annotated[bool, typer.Option("--yes", "-y", help="Skip interactive confirmation")] = False,
    pxe_interface: Annotated[str, typer.Option("--interface", help="PXE interface to clean")] = "virbr-pxe",
    pxe_ip: Annotated[str, typer.Option("--ip", help="PXE IP to remove")] = "192.168.100.2",
    pxe_cidr: Annotated[int, typer.Option("--cidr", help="PXE CIDR to remove")] = 24,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Show command/env without execution")] = False,
) -> None:
    try:
        cfg = TeardownConfig(
            method=method,
            remove_images=remove_images,
            vm_name=vm_name,
            skip_confirm=yes,
            pxe_interface=pxe_interface,
            pxe_ip=pxe_ip,
            pxe_cidr=pxe_cidr,
        )
    except ValueError as exc:
        _raise_validation(exc)

    if cfg.method == DeploymentMethod.DOCKER_COMPOSE:
        ComposeTeardown().run(cfg, dry_run=dry_run)
        return

    exit_code = run_script("teardown.sh", cfg.to_shell_args(), cfg.to_env(), dry_run=dry_run)
    if exit_code != 0:
        raise typer.Exit(code=exit_code)


def main() -> None:
    app()


if __name__ == "__main__":
    main()
