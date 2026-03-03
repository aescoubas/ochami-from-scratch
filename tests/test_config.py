from __future__ import annotations

from pathlib import Path

import pytest

from ochami.config import (
    DeployConfig,
    DeploymentMethod,
    DiscoveryMethod,
    TeardownConfig,
)


def test_deploy_config_defaults() -> None:
    cfg = DeployConfig(method=DeploymentMethod.DOCKER_COMPOSE)

    assert cfg.method == DeploymentMethod.DOCKER_COMPOSE
    assert cfg.pxe_interface == "virbr-pxe"
    assert cfg.pxe_ip == "192.168.100.2"
    assert cfg.pxe_cidr == 24
    assert cfg.mode == "libvirt"
    assert cfg.num_vms == 0
    assert cfg.discovery_method == DiscoveryMethod.STATIC
    assert cfg.dhcp_start == "192.168.100.100"
    assert cfg.dhcp_end == "192.168.100.200"
    assert cfg.dhcp_netmask == "255.255.255.0"
    assert cfg.dhcp_conflict_policy == "fail"


def test_deploy_config_rejects_invalid_ip() -> None:
    with pytest.raises(ValueError, match="pxe_ip"):
        DeployConfig(method=DeploymentMethod.MINIKUBE, pxe_ip="not-an-ip")


def test_deploy_config_requires_dhcp_range_pair() -> None:
    with pytest.raises(ValueError, match="dhcp_start and dhcp_end"):
        DeployConfig(method=DeploymentMethod.MINIKUBE, dhcp_start="192.168.1.10", dhcp_end="")


def test_deploy_config_magellan_requires_target() -> None:
    with pytest.raises(ValueError, match="magellan"):
        DeployConfig(
            method=DeploymentMethod.MINIKUBE,
            discovery_method=DiscoveryMethod.MAGELLAN,
        )


def test_deploy_config_rejects_missing_nodes_file(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist.csv"

    with pytest.raises(ValueError, match="nodes_file"):
        DeployConfig(method=DeploymentMethod.QUADLETS, nodes_file=missing)


def test_teardown_config_defaults() -> None:
    cfg = TeardownConfig(method=DeploymentMethod.DOCKER_COMPOSE)

    assert cfg.remove_images is False
    assert cfg.vm_name == "virtual-compute-node"
    assert cfg.skip_confirm is False
    assert cfg.pxe_interface == "virbr-pxe"
    assert cfg.pxe_ip == "192.168.100.2"
    assert cfg.pxe_cidr == 24


def test_teardown_config_rejects_invalid_cidr() -> None:
    with pytest.raises(ValueError, match="pxe_cidr"):
        TeardownConfig(method=DeploymentMethod.MINIKUBE, pxe_cidr=40)
