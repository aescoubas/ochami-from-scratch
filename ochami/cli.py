from __future__ import annotations

import os
from pathlib import Path
from typing import Annotated, Any

import typer

from ochami.config import (
    DeployConfig,
    DeployMode,
    DeploymentMethod,
    DnsConflictPolicy,
    DiscoveryMethod,
    TeardownConfig,
    load_config_file,
    merge_deploy_config,
)
from ochami.console import Console
from ochami.deploy.compose import ComposeDeployer
from ochami.deploy.minikube import MinikubeDeployer
from ochami.deploy.quadlets import QuadletsDeployer
from ochami.utils import make_quiet_runner
from ochami.mcp.server import main as mcp_server_main
from ochami.registry import RegistryManager
from ochami.teardown.compose import ComposeTeardown
from ochami.teardown.minikube import MinikubeTeardown
from ochami.teardown.quadlets import QuadletsTeardown

app = typer.Typer(help="OpenCHAMI Python CLI.")


def _raise_validation(error: ValueError) -> None:
    raise typer.BadParameter(str(error))


def _collect_deploy_overrides(
    *,
    method: DeploymentMethod | None,
    rebuild: bool | None,
    dhcp_start: str | None,
    dhcp_end: str | None,
    dhcp_netmask: str | None,
    dhcp_conflict_policy: DnsConflictPolicy | None,
    set_fs_protected_regular: bool | None,
    pxe_interface: str | None,
    pxe_ip: str | None,
    pxe_cidr: int | None,
    phy_iface: str | None,
    mode: DeployMode | None,
    num_vms: int | None,
    nodes_file: Path | None,
    smd_ref: str | None,
    bss_ref: str | None,
    pcs_ref: str | None,
    smd_repo_uri: str | None,
    bss_repo_uri: str | None,
    pcs_repo_uri: str | None,
    cloud_init_ref: str | None,
    cloud_init_repo_uri: str | None,
    discovery_method: DiscoveryMethod | None,
    magellan_subnets: str | None,
    magellan_hosts: str | None,
    magellan_subnet_mask: str | None,
    magellan_bmc_user: str | None,
    magellan_bmc_pass: str | None,
    magellan_bmc_id_map: str | None,
    magellan_cache: str | None,
    magellan_insecure: bool | None,
    magellan_ref: str | None,
    magellan_repo_uri: str | None,
    enable_stork: bool | None,
) -> dict[str, Any]:
    """Return a dict of only the CLI arguments that were explicitly provided."""
    candidates: dict[str, Any] = {
        "method": method,
        "rebuild": rebuild,
        "dhcp_start": dhcp_start,
        "dhcp_end": dhcp_end,
        "dhcp_netmask": dhcp_netmask,
        "dhcp_conflict_policy": dhcp_conflict_policy,
        "set_fs_protected_regular": set_fs_protected_regular,
        "pxe_interface": pxe_interface,
        "pxe_ip": pxe_ip,
        "pxe_cidr": pxe_cidr,
        "phy_iface": phy_iface,
        "mode": mode,
        "num_vms": num_vms,
        "nodes_file": nodes_file,
        "smd_ref": smd_ref,
        "bss_ref": bss_ref,
        "pcs_ref": pcs_ref,
        "smd_repo_uri": smd_repo_uri,
        "bss_repo_uri": bss_repo_uri,
        "pcs_repo_uri": pcs_repo_uri,
        "cloud_init_ref": cloud_init_ref,
        "cloud_init_repo_uri": cloud_init_repo_uri,
        "discovery_method": discovery_method,
        "magellan_subnets": magellan_subnets,
        "magellan_hosts": magellan_hosts,
        "magellan_subnet_mask": magellan_subnet_mask,
        "magellan_bmc_user": magellan_bmc_user,
        "magellan_bmc_pass": magellan_bmc_pass,
        "magellan_bmc_id_map": magellan_bmc_id_map,
        "magellan_cache": magellan_cache,
        "magellan_insecure": magellan_insecure,
        "magellan_ref": magellan_ref,
        "magellan_repo_uri": magellan_repo_uri,
        "enable_stork": enable_stork,
    }
    return {k: v for k, v in candidates.items() if v is not None}


@app.command("deploy")
def deploy(
    config_file: Annotated[
        Path | None,
        typer.Option("--config", "-c", help="YAML config file (defaults < file < CLI)"),
    ] = None,
    method: Annotated[
        DeploymentMethod | None,
        typer.Option("--method", help="Deployment method"),
    ] = None,
    rebuild: Annotated[bool | None, typer.Option("--rebuild", help="Force rebuild container images")] = None,
    dhcp_start: Annotated[str | None, typer.Option("--dhcp-start", help="DHCP pool start")] = None,
    dhcp_end: Annotated[str | None, typer.Option("--dhcp-end", help="DHCP pool end")] = None,
    dhcp_netmask: Annotated[str | None, typer.Option("--dhcp-netmask", help="DHCP netmask")] = None,
    fail_on_conflict: Annotated[
        bool,
        typer.Option("--fail-on-conflict", help="Fail if UDP/67 is in use"),
    ] = False,
    auto_kill: Annotated[
        bool,
        typer.Option("--auto-kill", help="Terminate conflicting UDP/67 process"),
    ] = False,
    set_fs_protected_regular: Annotated[
        bool | None,
        typer.Option(
            "--set-fs-protected-regular/--no-set-fs-protected-regular",
            help="Temporarily set fs.protected_regular=0 during prereq install",
        ),
    ] = None,
    pxe_interface: Annotated[str | None, typer.Option("--interface", help="PXE interface")] = None,
    pxe_ip: Annotated[str | None, typer.Option("--ip", help="Host IP on PXE interface")] = None,
    pxe_cidr: Annotated[int | None, typer.Option("--cidr", help="Host CIDR on PXE interface")] = None,
    phy_iface: Annotated[str | None, typer.Option("--phy-iface", help="Physical interface to bridge")] = None,
    mode: Annotated[
        DeployMode | None,
        typer.Option("--mode", help="Deployment mode: libvirt or hardware"),
    ] = None,
    num_vms: Annotated[int | None, typer.Option("--vms", help="Number of virtual compute nodes")] = None,
    nodes_file: Annotated[
        Path | None,
        typer.Option("--nodes-file", help="CSV file containing hardware nodes"),
    ] = None,
    smd_ref: Annotated[str | None, typer.Option("--smd-ref", help="SMD git ref")] = None,
    bss_ref: Annotated[str | None, typer.Option("--bss-ref", help="BSS git ref")] = None,
    pcs_ref: Annotated[str | None, typer.Option("--pcs-ref", help="PCS git ref")] = None,
    smd_repo_uri: Annotated[str | None, typer.Option("--smd-repo-uri", help="SMD repo URI")] = None,
    bss_repo_uri: Annotated[str | None, typer.Option("--bss-repo-uri", help="BSS repo URI")] = None,
    pcs_repo_uri: Annotated[str | None, typer.Option("--pcs-repo-uri", help="PCS repo URI")] = None,
    cloud_init_ref: Annotated[str | None, typer.Option("--cloud-init-ref", help="Cloud-init git ref")] = None,
    cloud_init_repo_uri: Annotated[str | None, typer.Option("--cloud-init-repo-uri", help="Cloud-init repo URI")] = None,
    discovery_method: Annotated[
        DiscoveryMethod | None,
        typer.Option("--discovery-method", help="Discovery method: static or magellan"),
    ] = None,
    magellan_subnets: Annotated[
        str | None,
        typer.Option("--magellan-subnets", help="Comma-separated Magellan scan subnets"),
    ] = None,
    magellan_hosts: Annotated[
        str | None,
        typer.Option("--magellan-hosts", help="Comma-separated Magellan hosts/URIs"),
    ] = None,
    magellan_subnet_mask: Annotated[
        str | None,
        typer.Option("--magellan-subnet-mask", help="Subnet mask used by Magellan scan"),
    ] = None,
    magellan_bmc_user: Annotated[
        str | None,
        typer.Option("--magellan-bmc-user", help="BMC username for Magellan collect"),
    ] = None,
    magellan_bmc_pass: Annotated[
        str | None,
        typer.Option("--magellan-bmc-pass", help="BMC password for Magellan collect"),
    ] = None,
    magellan_bmc_id_map: Annotated[
        str | None,
        typer.Option("--magellan-bmc-id-map", help="BMC ID map for Magellan collect"),
    ] = None,
    magellan_cache: Annotated[str | None, typer.Option("--magellan-cache", help="Magellan cache path")] = None,
    magellan_insecure: Annotated[
        bool | None,
        typer.Option("--magellan-insecure", help="Skip TLS verification for Magellan"),
    ] = None,
    magellan_ref: Annotated[str | None, typer.Option("--magellan-ref", help="Magellan git ref")] = None,
    magellan_repo_uri: Annotated[str | None, typer.Option("--magellan-repo-uri", help="Magellan repo URI")] = None,
    enable_stork: Annotated[
        bool | None,
        typer.Option("--enable-stork", help="Enable Stork DHCP monitoring UI"),
    ] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Show command/env without execution")] = False,
    verbose: Annotated[bool, typer.Option("--verbose", "-v", help="Show subprocess output")] = False,
) -> None:
    if fail_on_conflict and auto_kill:
        raise typer.BadParameter("choose only one of --fail-on-conflict or --auto-kill")

    # Resolve conflict policy from CLI flags (only if explicitly set)
    conflict_policy: DnsConflictPolicy | None = None
    if auto_kill:
        conflict_policy = DnsConflictPolicy.AUTO_KILL
    elif fail_on_conflict:
        conflict_policy = DnsConflictPolicy.FAIL

    # Load config file if provided
    file_values: dict[str, Any] = {}
    if config_file is not None:
        try:
            file_values = load_config_file(config_file)
        except (ValueError, FileNotFoundError) as exc:
            _raise_validation(ValueError(str(exc)))

    # Collect only explicitly-set CLI overrides (non-None values)
    cli_overrides = _collect_deploy_overrides(
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
        cloud_init_ref=cloud_init_ref,
        cloud_init_repo_uri=cloud_init_repo_uri,
        discovery_method=discovery_method,
        magellan_subnets=magellan_subnets,
        magellan_hosts=magellan_hosts,
        magellan_subnet_mask=magellan_subnet_mask,
        magellan_bmc_user=magellan_bmc_user,
        magellan_bmc_pass=magellan_bmc_pass,
        magellan_bmc_id_map=magellan_bmc_id_map,
        magellan_cache=magellan_cache,
        magellan_insecure=magellan_insecure,
        magellan_ref=magellan_ref,
        magellan_repo_uri=magellan_repo_uri,
        enable_stork=enable_stork,
    )

    # Merge: dataclass defaults < file < CLI
    merged = {**file_values, **cli_overrides}
    if "method" not in merged:
        raise typer.BadParameter("--method is required (via CLI or config file)")

    try:
        cfg = merge_deploy_config(file_values=file_values, cli_overrides=cli_overrides)
    except ValueError as exc:
        _raise_validation(exc)

    console = Console(verbose=verbose, dry_run=dry_run)
    runner = None if verbose else make_quiet_runner()

    if cfg.method == DeploymentMethod.DOCKER_COMPOSE:
        deployer = ComposeDeployer(**({"runner": runner} if runner else {}))
        deployer.run(cfg, dry_run=dry_run, console=console)
        return
    if cfg.method == DeploymentMethod.QUADLETS:
        deployer = QuadletsDeployer(**({"runner": runner} if runner else {}))
        deployer.run(cfg, dry_run=dry_run, console=console)
        return
    if cfg.method == DeploymentMethod.MINIKUBE:
        deployer = MinikubeDeployer(**({"runner": runner} if runner else {}))
        deployer.run(cfg, dry_run=dry_run, console=console)
        return

    raise typer.BadParameter(f"unsupported deployment method: {cfg.method.value}")


@app.command("check")
def check(
    config_file: Annotated[
        Path,
        typer.Option("--config", "-c", help="YAML config file to validate"),
    ] = Path("openchami.yaml"),
) -> None:
    """Validate a configuration file without deploying."""
    try:
        file_values = load_config_file(config_file)
    except FileNotFoundError:
        raise typer.BadParameter(f"config file not found: {config_file}")
    except ValueError as exc:
        _raise_validation(exc)

    if not file_values:
        raise typer.BadParameter("config file is empty")

    if "method" not in file_values:
        raise typer.BadParameter("config file must specify 'method'")

    try:
        merge_deploy_config(file_values=file_values, cli_overrides={})
    except ValueError as exc:
        _raise_validation(exc)

    typer.echo(f"config ok: {config_file}")


_DEFAULT_STATE_PATH = Path(".openchami-state.yaml")


@app.command("apply")
def apply(
    config_file: Annotated[
        Path | None,
        typer.Option("--config", "-c", help="YAML config file (defaults to openchami.yaml)"),
    ] = None,
    method: Annotated[
        DeploymentMethod | None,
        typer.Option("--method", help="Deployment method"),
    ] = None,
    force: Annotated[bool, typer.Option("--force", help="Force deploy even if config unchanged")] = False,
    rebuild: Annotated[bool | None, typer.Option("--rebuild", help="Force rebuild container images")] = None,
    dhcp_start: Annotated[str | None, typer.Option("--dhcp-start", help="DHCP pool start")] = None,
    dhcp_end: Annotated[str | None, typer.Option("--dhcp-end", help="DHCP pool end")] = None,
    dhcp_netmask: Annotated[str | None, typer.Option("--dhcp-netmask", help="DHCP netmask")] = None,
    fail_on_conflict: Annotated[
        bool,
        typer.Option("--fail-on-conflict", help="Fail if UDP/67 is in use"),
    ] = False,
    auto_kill: Annotated[
        bool,
        typer.Option("--auto-kill", help="Terminate conflicting UDP/67 process"),
    ] = False,
    set_fs_protected_regular: Annotated[
        bool | None,
        typer.Option(
            "--set-fs-protected-regular/--no-set-fs-protected-regular",
            help="Temporarily set fs.protected_regular=0 during prereq install",
        ),
    ] = None,
    pxe_interface: Annotated[str | None, typer.Option("--interface", help="PXE interface")] = None,
    pxe_ip: Annotated[str | None, typer.Option("--ip", help="Host IP on PXE interface")] = None,
    pxe_cidr: Annotated[int | None, typer.Option("--cidr", help="Host CIDR on PXE interface")] = None,
    phy_iface: Annotated[str | None, typer.Option("--phy-iface", help="Physical interface to bridge")] = None,
    mode: Annotated[
        DeployMode | None,
        typer.Option("--mode", help="Deployment mode: libvirt or hardware"),
    ] = None,
    num_vms: Annotated[int | None, typer.Option("--vms", help="Number of virtual compute nodes")] = None,
    nodes_file: Annotated[
        Path | None,
        typer.Option("--nodes-file", help="CSV file containing hardware nodes"),
    ] = None,
    smd_ref: Annotated[str | None, typer.Option("--smd-ref", help="SMD git ref")] = None,
    bss_ref: Annotated[str | None, typer.Option("--bss-ref", help="BSS git ref")] = None,
    pcs_ref: Annotated[str | None, typer.Option("--pcs-ref", help="PCS git ref")] = None,
    smd_repo_uri: Annotated[str | None, typer.Option("--smd-repo-uri", help="SMD repo URI")] = None,
    bss_repo_uri: Annotated[str | None, typer.Option("--bss-repo-uri", help="BSS repo URI")] = None,
    pcs_repo_uri: Annotated[str | None, typer.Option("--pcs-repo-uri", help="PCS repo URI")] = None,
    cloud_init_ref: Annotated[str | None, typer.Option("--cloud-init-ref", help="Cloud-init git ref")] = None,
    cloud_init_repo_uri: Annotated[str | None, typer.Option("--cloud-init-repo-uri", help="Cloud-init repo URI")] = None,
    discovery_method: Annotated[
        DiscoveryMethod | None,
        typer.Option("--discovery-method", help="Discovery method: static or magellan"),
    ] = None,
    magellan_subnets: Annotated[
        str | None,
        typer.Option("--magellan-subnets", help="Comma-separated Magellan scan subnets"),
    ] = None,
    magellan_hosts: Annotated[
        str | None,
        typer.Option("--magellan-hosts", help="Comma-separated Magellan hosts/URIs"),
    ] = None,
    magellan_subnet_mask: Annotated[
        str | None,
        typer.Option("--magellan-subnet-mask", help="Subnet mask used by Magellan scan"),
    ] = None,
    magellan_bmc_user: Annotated[
        str | None,
        typer.Option("--magellan-bmc-user", help="BMC username for Magellan collect"),
    ] = None,
    magellan_bmc_pass: Annotated[
        str | None,
        typer.Option("--magellan-bmc-pass", help="BMC password for Magellan collect"),
    ] = None,
    magellan_bmc_id_map: Annotated[
        str | None,
        typer.Option("--magellan-bmc-id-map", help="BMC ID map for Magellan collect"),
    ] = None,
    magellan_cache: Annotated[str | None, typer.Option("--magellan-cache", help="Magellan cache path")] = None,
    magellan_insecure: Annotated[
        bool | None,
        typer.Option("--magellan-insecure", help="Skip TLS verification for Magellan"),
    ] = None,
    magellan_ref: Annotated[str | None, typer.Option("--magellan-ref", help="Magellan git ref")] = None,
    magellan_repo_uri: Annotated[str | None, typer.Option("--magellan-repo-uri", help="Magellan repo URI")] = None,
    enable_stork: Annotated[
        bool | None,
        typer.Option("--enable-stork", help="Enable Stork DHCP monitoring UI"),
    ] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Show command/env without execution")] = False,
    verbose: Annotated[bool, typer.Option("--verbose", "-v", help="Show subprocess output")] = False,
) -> None:
    """Idempotent deploy: skip if config unchanged, run full deploy otherwise."""
    if fail_on_conflict and auto_kill:
        raise typer.BadParameter("choose only one of --fail-on-conflict or --auto-kill")

    conflict_policy: DnsConflictPolicy | None = None
    if auto_kill:
        conflict_policy = DnsConflictPolicy.AUTO_KILL
    elif fail_on_conflict:
        conflict_policy = DnsConflictPolicy.FAIL

    # Default config path for apply: openchami.yaml (silent if missing)
    effective_config = config_file
    if effective_config is None:
        default_path = Path("openchami.yaml")
        if default_path.is_file():
            effective_config = default_path

    file_values: dict[str, Any] = {}
    if effective_config is not None:
        try:
            file_values = load_config_file(effective_config)
        except (ValueError, FileNotFoundError) as exc:
            # Explicit --config that doesn't exist is an error
            if config_file is not None:
                _raise_validation(ValueError(str(exc)))

    cli_overrides = _collect_deploy_overrides(
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
        cloud_init_ref=cloud_init_ref,
        cloud_init_repo_uri=cloud_init_repo_uri,
        discovery_method=discovery_method,
        magellan_subnets=magellan_subnets,
        magellan_hosts=magellan_hosts,
        magellan_subnet_mask=magellan_subnet_mask,
        magellan_bmc_user=magellan_bmc_user,
        magellan_bmc_pass=magellan_bmc_pass,
        magellan_bmc_id_map=magellan_bmc_id_map,
        magellan_cache=magellan_cache,
        magellan_insecure=magellan_insecure,
        magellan_ref=magellan_ref,
        magellan_repo_uri=magellan_repo_uri,
        enable_stork=enable_stork,
    )

    merged = {**file_values, **cli_overrides}
    if "method" not in merged:
        raise typer.BadParameter("--method is required (via CLI or config file)")

    try:
        cfg = merge_deploy_config(file_values=file_values, cli_overrides=cli_overrides)
    except ValueError as exc:
        _raise_validation(exc)

    console = Console(verbose=verbose, dry_run=dry_run)
    runner_kwargs: dict[str, object] = {}
    if not verbose:
        runner_kwargs["runner"] = make_quiet_runner()

    deployer: ComposeDeployer | QuadletsDeployer | MinikubeDeployer
    if cfg.method == DeploymentMethod.DOCKER_COMPOSE:
        deployer = ComposeDeployer(**runner_kwargs)  # type: ignore[arg-type]
    elif cfg.method == DeploymentMethod.QUADLETS:
        deployer = QuadletsDeployer(**runner_kwargs)  # type: ignore[arg-type]
    elif cfg.method == DeploymentMethod.MINIKUBE:
        deployer = MinikubeDeployer(**runner_kwargs)  # type: ignore[arg-type]
    else:
        raise typer.BadParameter(f"unsupported deployment method: {cfg.method.value}")

    deployer.apply(cfg, state_path=_DEFAULT_STATE_PATH, force=force, dry_run=dry_run, console=console)


@app.command("teardown")
def teardown(
    config_file: Annotated[
        Path | None,
        typer.Option("--config", "-c", help="YAML config file (shared with deploy)"),
    ] = None,
    method: Annotated[
        DeploymentMethod | None,
        typer.Option("--method", help="Teardown method"),
    ] = None,
    remove_images: Annotated[bool, typer.Option("--remove-images", help="Also remove container images")] = False,
    vm_name: Annotated[str | None, typer.Option("--vm-name", help="VM name pattern to delete")] = None,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="Skip interactive confirmation")] = False,
    pxe_interface: Annotated[str | None, typer.Option("--interface", help="PXE interface to clean")] = None,
    pxe_ip: Annotated[str | None, typer.Option("--ip", help="PXE IP to remove")] = None,
    pxe_cidr: Annotated[int | None, typer.Option("--cidr", help="PXE CIDR to remove")] = None,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Show command/env without execution")] = False,
) -> None:
    # Load shared config file for fields common with deploy (method, pxe_*)
    file_values: dict[str, Any] = {}
    if config_file is not None:
        try:
            all_values = load_config_file(config_file)
        except (ValueError, FileNotFoundError) as exc:
            _raise_validation(ValueError(str(exc)))
        # Pick only teardown-relevant keys
        _TEARDOWN_KEYS = {"method", "pxe_interface", "pxe_ip", "pxe_cidr"}
        file_values = {k: v for k, v in all_values.items() if k in _TEARDOWN_KEYS}

    # Build CLI overrides (only non-None)
    cli_overrides: dict[str, Any] = {}
    if method is not None:
        cli_overrides["method"] = method
    if vm_name is not None:
        cli_overrides["vm_name"] = vm_name
    if pxe_interface is not None:
        cli_overrides["pxe_interface"] = pxe_interface
    if pxe_ip is not None:
        cli_overrides["pxe_ip"] = pxe_ip
    if pxe_cidr is not None:
        cli_overrides["pxe_cidr"] = pxe_cidr
    if remove_images:
        cli_overrides["remove_images"] = True
    if yes:
        cli_overrides["skip_confirm"] = True

    merged = {**file_values, **cli_overrides}
    if "method" not in merged:
        raise typer.BadParameter("--method is required (via CLI or config file)")

    try:
        cfg = TeardownConfig(**merged)
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
