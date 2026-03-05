from __future__ import annotations

import os
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
from ochami.deploy.minikube import MinikubeDeployer
from ochami.deploy.quadlets import QuadletsDeployer
from ochami.mcp.server import main as mcp_server_main
from ochami.registry import RegistryManager
from ochami.teardown.compose import ComposeTeardown
from ochami.teardown.minikube import MinikubeTeardown
from ochami.teardown.quadlets import QuadletsTeardown

app = typer.Typer(help="OpenCHAMI Python CLI.")


def _raise_validation(error: ValueError) -> None:
    raise typer.BadParameter(str(error))


@app.command("deploy")
def deploy(
    method: Annotated[
        DeploymentMethod,
        typer.Option("--method", help="Deployment method"),
    ],
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
        typer.Option(
            "--set-fs-protected-regular/--no-set-fs-protected-regular",
            help="Temporarily set fs.protected_regular=0 during prereq install",
        ),
    ] = True,
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
    if cfg.method == DeploymentMethod.QUADLETS:
        QuadletsDeployer().run(cfg, dry_run=dry_run)
        return
    if cfg.method == DeploymentMethod.MINIKUBE:
        MinikubeDeployer().run(cfg, dry_run=dry_run)
        return

    raise typer.BadParameter(f"unsupported deployment method: {cfg.method.value}")


@app.command("teardown")
def teardown(
    method: Annotated[
        DeploymentMethod,
        typer.Option("--method", help="Teardown method"),
    ],
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
    if cfg.method == DeploymentMethod.QUADLETS:
        QuadletsTeardown().run(cfg, dry_run=dry_run)
        return
    if cfg.method == DeploymentMethod.MINIKUBE:
        MinikubeTeardown().run(cfg, dry_run=dry_run)
        return

    raise typer.BadParameter(f"unsupported teardown method: {cfg.method.value}")


@app.command("mcp")
def mcp(
    mode: Annotated[str, typer.Option("--mode", help="MCP mode: read-only or read-write")] = "read-only",
    base_url: Annotated[str, typer.Option("--base-url", help="OpenCHAMI API base URL")] = "",
    timeout: Annotated[int, typer.Option("--timeout", help="MCP request timeout (seconds)")] = 10,
    enable_writes: Annotated[
        bool,
        typer.Option("--enable-writes", help="Enable write-capable MCP tools in read-write mode"),
    ] = False,
) -> None:
    if mode not in {"read-only", "read-write"}:
        raise typer.BadParameter("--mode must be read-only or read-write")
    if enable_writes:
        os.environ["OPENCHAMI_MCP_ENABLE_WRITES"] = "true"

    argv: list[str] = ["--mode", mode, "--timeout", str(timeout)]
    if base_url:
        argv.extend(["--base-url", base_url])
    raise typer.Exit(code=mcp_server_main(argv))


@app.command("register-node")
def register_node(
    mac: Annotated[str, typer.Option("--mac", help="Node MAC address")],
    ip: Annotated[str, typer.Option("--ip", help="Node IP address")],
    component_id: Annotated[str, typer.Option("--component-id", help="SMD component xname")],
    nid: Annotated[int, typer.Option("--nid", help="Numeric node ID")],
    bmc_ip: Annotated[str, typer.Option("--bmc-ip", help="BMC IP address")],
    bmc_user: Annotated[str, typer.Option("--bmc-user", help="BMC username")],
    bmc_pass: Annotated[str, typer.Option("--bmc-pass", help="BMC password")],
    method: Annotated[
        DeploymentMethod,
        typer.Option("--method", help="Deployment method for service endpoint resolution"),
    ] = DeploymentMethod.MINIKUBE,
    host_ip: Annotated[str, typer.Option("--host-ip", help="Host IP used for local reverse-proxy routes")] = "192.168.100.2",
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Show validation only")] = False,
) -> None:
    manager = RegistryManager(Path(__file__).resolve().parents[1])
    manager.register_hardware_node(
        mac=mac,
        ip=ip,
        component_id=component_id,
        nid=nid,
        bmc_ip=bmc_ip,
        bmc_user=bmc_user,
        bmc_pass=bmc_pass,
        host_ip=host_ip,
        orchestrator=method.value,
        dry_run=dry_run,
    )


def main() -> None:
    app()


if __name__ == "__main__":
    main()
