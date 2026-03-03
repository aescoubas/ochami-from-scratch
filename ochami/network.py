from __future__ import annotations

import re
from pathlib import Path
import time

from ochami.config import DeployConfig, DeployMode, DnsConflictPolicy, TeardownConfig
from ochami.utils import is_macos, run, run_output


PXE_NETWORK_XML = """<network>
  <name>pxe-net</name>
  <uuid>c8f874f7-dd7a-465c-862a-ec30f41ac4bb</uuid>
  <bridge name='virbr-pxe' stp='on' delay='0'/>
  <mac address='52:54:00:d8:3f:37'/>
  <dns enable='no'/>
  <ip address='192.168.100.1' netmask='255.255.255.0'>
  </ip>
</network>
"""


class NetworkManager:
    def __init__(self, project_root: Path, runner=run, output_runner=run_output, macos: bool | None = None) -> None:
        self.project_root = project_root
        self._run = runner
        self._run_output = output_runner
        self._is_macos = is_macos() if macos is None else macos

    def configure_for_compose(self, config: DeployConfig, dry_run: bool) -> str:
        if self._is_macos:
            return config.pxe_ip

        active_interface = config.pxe_interface
        bridge_interface = config.phy_iface
        if config.mode == DeployMode.HARDWARE and config.phy_iface:
            active_interface = config.phy_iface

        if config.mode == DeployMode.LIBVIRT:
            self._configure_libvirt_network(active_interface, dry_run=dry_run)

        self._setup_host_network(
            host_iface=active_interface,
            host_ip=config.pxe_ip,
            cidr=config.pxe_cidr,
            phy_iface=bridge_interface,
            dry_run=dry_run,
        )
        self._check_dhcp_port_conflict(active_interface, config.dhcp_conflict_policy, dry_run=dry_run)
        self._configure_firewall(active_interface, dry_run=dry_run)
        return config.pxe_ip

    def cleanup_for_compose(self, config: TeardownConfig, dry_run: bool) -> None:
        if self._is_macos:
            return
        self._destroy_pxe_network(dry_run=dry_run)
        self._cleanup_host_networking(config.pxe_interface, config.pxe_ip, config.pxe_cidr, dry_run=dry_run)

    def configure_for_quadlets(self, config: DeployConfig, dry_run: bool) -> str:
        return self.configure_for_compose(config, dry_run=dry_run)

    def cleanup_for_quadlets(self, config: TeardownConfig, dry_run: bool) -> None:
        self.cleanup_for_compose(config, dry_run=dry_run)

    def configure_for_minikube(self, config: DeployConfig, dry_run: bool) -> tuple[str, str]:
        if self._is_macos:
            host_ip = self._run_output(["minikube", "ip"], check=False, dry_run=dry_run).strip()
            if not host_ip and not dry_run:
                host_ip = "127.0.0.1"
            if not host_ip:
                host_ip = config.pxe_ip
            return host_ip, config.pxe_interface

        active_interface = config.pxe_interface
        bridge_interface = config.phy_iface

        if config.mode == DeployMode.HARDWARE:
            active_interface = self._configure_hardware_network(config.pxe_interface, config.phy_iface, dry_run=dry_run)
            bridge_interface = ""

        if config.mode == DeployMode.LIBVIRT:
            self._configure_libvirt_network(active_interface, dry_run=dry_run)

        self._setup_host_network(
            host_iface=active_interface,
            host_ip=config.pxe_ip,
            cidr=config.pxe_cidr,
            phy_iface=bridge_interface,
            dry_run=dry_run,
        )
        self._check_dhcp_port_conflict(active_interface, config.dhcp_conflict_policy, dry_run=dry_run)
        self._configure_firewall(active_interface, dry_run=dry_run)
        return config.pxe_ip, active_interface

    def cleanup_for_minikube(self, config: TeardownConfig, dry_run: bool) -> None:
        self.cleanup_for_compose(config, dry_run=dry_run)

    def _configure_hardware_network(self, pxe_interface: str, phy_iface: str, dry_run: bool) -> str:
        if self._run(["virsh", "net-info", "default"], check=False, dry_run=dry_run) == 0:
            info = self._run_output(["virsh", "net-info", "default"], check=False, dry_run=dry_run)
            if re.search(r"Active:\s+yes", info):
                self._run(["sudo", "virsh", "net-destroy", "default"], check=False, dry_run=dry_run)
            self._run(["sudo", "virsh", "net-autostart", "--disable", "default"], check=False, dry_run=dry_run)

        if pxe_interface == "virbr-pxe" and phy_iface:
            return phy_iface
        return pxe_interface

    def _configure_libvirt_network(self, pxe_interface: str, dry_run: bool) -> None:
        if self._is_macos:
            return
        if pxe_interface != "virbr-pxe":
            return
        if self._run(["virsh", "net-info", "pxe-net"], check=False, dry_run=dry_run) == 0:
            return

        define_cmd = "cat <<'EOF' | virsh net-define /dev/stdin\n" + PXE_NETWORK_XML + "EOF\n"
        self._run(["bash", "-lc", define_cmd], dry_run=dry_run)
        self._run(["virsh", "net-start", "pxe-net"], dry_run=dry_run, check=False)
        self._run(["virsh", "net-autostart", "pxe-net"], dry_run=dry_run, check=False)

    def _setup_host_network(self, *, host_iface: str, host_ip: str, cidr: int, phy_iface: str, dry_run: bool) -> None:
        if self._is_macos:
            return

        if self._minikube_vm_present(dry_run=dry_run):
            self._setup_minikube_vm_network(host_ip=host_ip, cidr=cidr, dry_run=dry_run)
            return

        if self._run(["ip", "link", "show", host_iface], check=False, dry_run=dry_run) != 0:
            raise RuntimeError(f"host interface {host_iface!r} not found")

        if host_iface == "virbr-pxe":
            if self._run(["ip", "link", "show", "ochami-dummy"], check=False, dry_run=dry_run) != 0:
                self._run(["sudo", "ip", "link", "add", "ochami-dummy", "type", "dummy"], dry_run=dry_run)
            self._run(["sudo", "ip", "link", "set", "ochami-dummy", "master", host_iface], dry_run=dry_run, check=False)
            self._run(["sudo", "ip", "link", "set", "ochami-dummy", "up"], dry_run=dry_run, check=False)

            if phy_iface and self._run(["ip", "link", "show", phy_iface], check=False, dry_run=dry_run) == 0:
                self._run(["sudo", "ip", "link", "set", "dev", phy_iface, "up"], dry_run=dry_run, check=False)
                self._run(["sudo", "ip", "link", "set", "dev", phy_iface, "master", host_iface], dry_run=dry_run, check=False)

        interface_info = self._run_output(["ip", "addr", "show", host_iface], check=False, dry_run=dry_run)
        if f"inet {host_ip}/" not in interface_info:
            self._run(["sudo", "ip", "addr", "add", f"{host_ip}/{cidr}", "dev", host_iface], dry_run=dry_run)

    def _minikube_vm_present(self, *, dry_run: bool) -> bool:
        listing = self._run_output(["virsh", "list", "--all", "--name"], check=False, dry_run=dry_run)
        return any(line.strip() == "minikube" for line in listing.splitlines())

    def _setup_minikube_vm_network(self, *, host_ip: str, cidr: int, dry_run: bool) -> None:
        domiflist = self._run_output(["virsh", "domiflist", "minikube"], check=False, dry_run=dry_run)
        if "pxe-net" not in domiflist:
            self._run(
                [
                    "virsh",
                    "attach-interface",
                    "--domain",
                    "minikube",
                    "--type",
                    "network",
                    "--source",
                    "pxe-net",
                    "--model",
                    "virtio",
                    "--config",
                    "--live",
                ],
                dry_run=dry_run,
                check=False,
            )
            if not dry_run:
                time.sleep(5)
            domiflist = self._run_output(["virsh", "domiflist", "minikube"], check=False, dry_run=dry_run)

        mac_address = ""
        for line in domiflist.splitlines():
            columns = line.split()
            if len(columns) >= 5 and columns[2] == "pxe-net":
                mac_address = columns[4]
                break
        if not mac_address:
            return

        script = (
            "sudo bash -lc \""
            "echo 1 > /sys/bus/pci/rescan; "
            "sleep 1; "
            f"IFACE=$(ip -o link | grep -i '{mac_address}' | awk -F': ' '{{print $2}}' | head -n1); "
            "[ -n \\\"$IFACE\\\" ] || exit 1; "
            "ip link set \\\"$IFACE\\\" up; "
            f"ip addr show \\\"$IFACE\\\" | grep -q '{host_ip}/' || ip addr add '{host_ip}/{cidr}' dev \\\"$IFACE\\\""
            "\""
        )
        self._run(["minikube", "ssh", script], dry_run=dry_run, check=False)

    def _check_dhcp_port_conflict(self, pxe_interface: str, policy: DnsConflictPolicy, dry_run: bool) -> None:
        del pxe_interface
        if self._is_macos:
            raw = self._run_output(["sudo", "lsof", "-i", "UDP:67", "-P", "-n"], check=False, dry_run=dry_run)
            lines = [line for line in raw.splitlines() if line and not line.startswith("COMMAND")]
            pids = {line.split()[1] for line in lines if len(line.split()) > 1}
        else:
            raw = self._run_output(["sudo", "ss", "-ulnp", "sport = :67"], check=False, dry_run=dry_run)
            lines = [line for line in raw.splitlines() if line and not line.startswith("State")]
            pids = set(re.findall(r"pid=(\d+)", "\n".join(lines)))
            if not pids:
                fallback = self._run_output(["sudo", "fuser", "67/udp"], check=False, dry_run=dry_run)
                pids = {token for token in re.split(r"\s+", fallback.strip()) if token.isdigit()}

        if not pids:
            return
        if policy == DnsConflictPolicy.FAIL:
            raise RuntimeError("UDP port 67 is already in use")

        for pid in sorted(pids):
            self._run(["sudo", "kill", pid], check=False, dry_run=dry_run)
        if not dry_run:
            time.sleep(1)

    def _configure_firewall(self, pxe_interface: str, dry_run: bool) -> None:
        if self._is_macos:
            return
        if self._run(["systemctl", "is-active", "--quiet", "firewalld"], check=False, dry_run=dry_run) != 0:
            return
        self._run(
            ["sudo", "firewall-cmd", "--zone=trusted", f"--add-interface={pxe_interface}", "--permanent"],
            check=False,
            dry_run=dry_run,
        )
        self._run(["sudo", "firewall-cmd", "--reload"], check=False, dry_run=dry_run)

    def _destroy_pxe_network(self, dry_run: bool) -> None:
        if self._run(["sudo", "virsh", "net-info", "pxe-net"], check=False, dry_run=dry_run) != 0:
            return
        self._run(["sudo", "virsh", "net-destroy", "pxe-net"], check=False, dry_run=dry_run)
        self._run(["sudo", "virsh", "net-undefine", "pxe-net"], check=False, dry_run=dry_run)

    def _cleanup_host_networking(self, host_iface: str, host_ip: str, host_cidr: int, dry_run: bool) -> None:
        if self._run(["systemctl", "is-active", "--quiet", "firewalld"], check=False, dry_run=dry_run) == 0:
            self._run(
                ["sudo", "firewall-cmd", "--zone=trusted", f"--remove-interface={host_iface}", "--permanent"],
                check=False,
                dry_run=dry_run,
            )
            self._run(["sudo", "firewall-cmd", "--reload"], check=False, dry_run=dry_run)

        if self._run(["ip", "link", "show", "ochami-dummy"], check=False, dry_run=dry_run) == 0:
            self._run(["sudo", "ip", "link", "delete", "ochami-dummy"], check=False, dry_run=dry_run)

        iface_output = self._run_output(["ip", "addr", "show", host_iface], check=False, dry_run=dry_run)
        if f"inet {host_ip}/" in iface_output:
            self._run(["sudo", "ip", "addr", "del", f"{host_ip}/{host_cidr}", "dev", host_iface], check=False, dry_run=dry_run)
