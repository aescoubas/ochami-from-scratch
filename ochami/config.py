from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from pathlib import Path
import ipaddress


class DeploymentMethod(str, Enum):
    MINIKUBE = "minikube"
    QUADLETS = "quadlets"
    DOCKER_COMPOSE = "docker-compose"


class DiscoveryMethod(str, Enum):
    STATIC = "static"
    MAGELLAN = "magellan"


class DnsConflictPolicy(str, Enum):
    FAIL = "fail"
    AUTO_KILL = "auto-kill"


class DeployMode(str, Enum):
    LIBVIRT = "libvirt"
    HARDWARE = "hardware"


def _validate_ipv4(value: str, field_name: str) -> None:
    try:
        ipaddress.IPv4Address(value)
    except ipaddress.AddressValueError as exc:
        raise ValueError(f"{field_name} must be a valid IPv4 address: {value!r}") from exc


def _validate_non_negative(value: int, field_name: str) -> None:
    if value < 0:
        raise ValueError(f"{field_name} must be a non-negative integer")


def _validate_cidr(value: int, field_name: str) -> None:
    if value < 0 or value > 32:
        raise ValueError(f"{field_name} must be between 0 and 32")


@dataclass(slots=True)
class DeployConfig:
    method: DeploymentMethod
    rebuild: bool = False
    dhcp_start: str = "192.168.100.100"
    dhcp_end: str = "192.168.100.200"
    dhcp_netmask: str = "255.255.255.0"
    dhcp_conflict_policy: DnsConflictPolicy = DnsConflictPolicy.FAIL
    set_fs_protected_regular: bool = True
    pxe_interface: str = "virbr-pxe"
    pxe_ip: str = "192.168.100.2"
    pxe_cidr: int = 24
    phy_iface: str = ""
    mode: DeployMode = DeployMode.LIBVIRT
    num_vms: int = 0
    nodes_file: Path | None = None
    smd_ref: str = "main"
    bss_ref: str = "main"
    pcs_ref: str = "main"
    smd_repo_uri: str = "https://github.com/aescoubas/ochami-smd.git"
    bss_repo_uri: str = "https://github.com/aescoubas/ochami-bss.git"
    pcs_repo_uri: str = "https://github.com/OpenCHAMI/power-control.git"
    discovery_method: DiscoveryMethod = DiscoveryMethod.STATIC
    magellan_subnets: str = ""
    magellan_hosts: str = ""
    magellan_subnet_mask: str = ""
    magellan_bmc_user: str = ""
    magellan_bmc_pass: str = ""
    magellan_bmc_id_map: str = ""
    magellan_cache: str = ""
    magellan_insecure: bool = False

    def __post_init__(self) -> None:
        self.validate()

    def validate(self) -> None:
        if self.mode not in {DeployMode.LIBVIRT, DeployMode.HARDWARE}:
            raise ValueError("mode must be either 'libvirt' or 'hardware'")

        _validate_ipv4(self.pxe_ip, "pxe_ip")
        _validate_cidr(self.pxe_cidr, "pxe_cidr")
        _validate_non_negative(self.num_vms, "num_vms")

        if bool(self.dhcp_start) != bool(self.dhcp_end):
            raise ValueError("dhcp_start and dhcp_end must be provided together")
        if self.dhcp_start:
            _validate_ipv4(self.dhcp_start, "dhcp_start")
            _validate_ipv4(self.dhcp_end, "dhcp_end")
        if self.dhcp_netmask:
            _validate_ipv4(self.dhcp_netmask, "dhcp_netmask")

        if self.nodes_file is not None and not self.nodes_file.is_file():
            raise ValueError(f"nodes_file does not exist: {self.nodes_file}")

        for key, value in {
            "smd_ref": self.smd_ref,
            "bss_ref": self.bss_ref,
            "pcs_ref": self.pcs_ref,
            "smd_repo_uri": self.smd_repo_uri,
            "bss_repo_uri": self.bss_repo_uri,
            "pcs_repo_uri": self.pcs_repo_uri,
        }.items():
            if not value.strip():
                raise ValueError(f"{key} must be non-empty")

        if self.discovery_method not in {DiscoveryMethod.STATIC, DiscoveryMethod.MAGELLAN}:
            raise ValueError("discovery_method must be 'static' or 'magellan'")

        if self.discovery_method == DiscoveryMethod.MAGELLAN:
            if self.nodes_file is not None:
                raise ValueError("nodes_file cannot be used with discovery_method=magellan")
            if not self.magellan_subnets.strip() and not self.magellan_hosts.strip():
                raise ValueError("magellan discovery requires magellan_subnets and/or magellan_hosts")
            if bool(self.magellan_bmc_user) != bool(self.magellan_bmc_pass):
                raise ValueError("magellan_bmc_user and magellan_bmc_pass must be provided together")

        if self.magellan_subnet_mask:
            _validate_ipv4(self.magellan_subnet_mask, "magellan_subnet_mask")
        if self.magellan_cache and not self.magellan_cache.strip():
            raise ValueError("magellan_cache must be non-empty when set")

    def to_shell_args(self) -> list[str]:
        args = ["--method", self.method.value]

        if self.rebuild:
            args.append("--rebuild")

        args.extend(
            [
                "--dhcp-start",
                self.dhcp_start,
                "--dhcp-end",
                self.dhcp_end,
                "--dhcp-netmask",
                self.dhcp_netmask,
                "--interface",
                self.pxe_interface,
                "--ip",
                self.pxe_ip,
                "--cidr",
                str(self.pxe_cidr),
                "--mode",
                self.mode.value,
                "--vms",
                str(self.num_vms),
                "--smd-ref",
                self.smd_ref,
                "--bss-ref",
                self.bss_ref,
                "--pcs-ref",
                self.pcs_ref,
                "--smd-repo-uri",
                self.smd_repo_uri,
                "--bss-repo-uri",
                self.bss_repo_uri,
                "--pcs-repo-uri",
                self.pcs_repo_uri,
                "--discovery-method",
                self.discovery_method.value,
            ]
        )

        if self.dhcp_conflict_policy == DnsConflictPolicy.AUTO_KILL:
            args.append("--auto-kill")
        else:
            args.append("--fail-on-conflict")

        if self.set_fs_protected_regular:
            args.append("--set-fs-protected-regular")
        if self.phy_iface:
            args.extend(["--phy-iface", self.phy_iface])
        if self.nodes_file is not None:
            args.extend(["--nodes-file", str(self.nodes_file)])
        if self.magellan_subnets:
            args.extend(["--magellan-subnets", self.magellan_subnets])
        if self.magellan_hosts:
            args.extend(["--magellan-hosts", self.magellan_hosts])
        if self.magellan_subnet_mask:
            args.extend(["--magellan-subnet-mask", self.magellan_subnet_mask])
        if self.magellan_bmc_user:
            args.extend(["--magellan-bmc-user", self.magellan_bmc_user])
        if self.magellan_bmc_pass:
            args.extend(["--magellan-bmc-pass", self.magellan_bmc_pass])
        if self.magellan_bmc_id_map:
            args.extend(["--magellan-bmc-id-map", self.magellan_bmc_id_map])
        if self.magellan_cache:
            args.extend(["--magellan-cache", self.magellan_cache])
        if self.magellan_insecure:
            args.append("--magellan-insecure")

        return args

    def to_env(self) -> dict[str, str]:
        env = {
            "OPENCHAMI_METHOD": self.method.value,
            "OPENCHAMI_PXE_INTERFACE": self.pxe_interface,
            "OPENCHAMI_PXE_IP": self.pxe_ip,
            "OPENCHAMI_PXE_CIDR": str(self.pxe_cidr),
            "OPENCHAMI_MODE": self.mode.value,
            "OPENCHAMI_NUM_VMS": str(self.num_vms),
            "OPENCHAMI_DISCOVERY_METHOD": self.discovery_method.value,
            "OPENCHAMI_DHCP_START": self.dhcp_start,
            "OPENCHAMI_DHCP_END": self.dhcp_end,
            "OPENCHAMI_DHCP_NETMASK": self.dhcp_netmask,
            "OPENCHAMI_DHCP_CONFLICT_POLICY": self.dhcp_conflict_policy.value,
            "OPENCHAMI_SMD_REF": self.smd_ref,
            "OPENCHAMI_BSS_REF": self.bss_ref,
            "OPENCHAMI_PCS_REF": self.pcs_ref,
            "OPENCHAMI_SMD_REPO_URI": self.smd_repo_uri,
            "OPENCHAMI_BSS_REPO_URI": self.bss_repo_uri,
            "OPENCHAMI_PCS_REPO_URI": self.pcs_repo_uri,
            "OPENCHAMI_MAGELLAN_SUBNETS": self.magellan_subnets,
            "OPENCHAMI_MAGELLAN_HOSTS": self.magellan_hosts,
            "OPENCHAMI_MAGELLAN_SUBNET_MASK": self.magellan_subnet_mask,
            "OPENCHAMI_MAGELLAN_BMC_USER": self.magellan_bmc_user,
            "OPENCHAMI_MAGELLAN_BMC_ID_MAP": self.magellan_bmc_id_map,
            "OPENCHAMI_MAGELLAN_CACHE": self.magellan_cache,
            "OPENCHAMI_REBUILD": str(self.rebuild).lower(),
            "OPENCHAMI_SET_FS_PROTECTED_REGULAR": str(self.set_fs_protected_regular).lower(),
            "OPENCHAMI_MAGELLAN_INSECURE": str(self.magellan_insecure).lower(),
        }
        if self.nodes_file is not None:
            env["OPENCHAMI_NODES_FILE"] = str(self.nodes_file)
        if self.phy_iface:
            env["OPENCHAMI_PHY_IFACE"] = self.phy_iface
        return env


@dataclass(slots=True)
class TeardownConfig:
    method: DeploymentMethod
    remove_images: bool = False
    vm_name: str = "virtual-compute-node"
    skip_confirm: bool = False
    pxe_interface: str = "virbr-pxe"
    pxe_ip: str = "192.168.100.2"
    pxe_cidr: int = 24

    def __post_init__(self) -> None:
        self.validate()

    def validate(self) -> None:
        _validate_ipv4(self.pxe_ip, "pxe_ip")
        _validate_cidr(self.pxe_cidr, "pxe_cidr")

    def to_shell_args(self) -> list[str]:
        args = [
            "--method",
            self.method.value,
            "--vm-name",
            self.vm_name,
            "--interface",
            self.pxe_interface,
            "--ip",
            self.pxe_ip,
            "--cidr",
            str(self.pxe_cidr),
        ]
        if self.remove_images:
            args.append("--remove-images")
        if self.skip_confirm:
            args.append("--yes")
        return args

    def to_env(self) -> dict[str, str]:
        return {
            "OPENCHAMI_METHOD": self.method.value,
            "OPENCHAMI_REMOVE_IMAGES": str(self.remove_images).lower(),
            "OPENCHAMI_VM_NAME": self.vm_name,
            "OPENCHAMI_PXE_INTERFACE": self.pxe_interface,
            "OPENCHAMI_PXE_IP": self.pxe_ip,
            "OPENCHAMI_PXE_CIDR": str(self.pxe_cidr),
            "OPENCHAMI_SKIP_CONFIRM": str(self.skip_confirm).lower(),
        }
