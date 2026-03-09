from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from ochami.registry import RegistryManager, ServiceEndpoints


def test_register_node_prunes_stale_ethernet_interfaces_and_syncs_kea(tmp_path: Path) -> None:
    commands: list[list[str]] = []
    requests: list[tuple[str, str, object | None]] = []

    def fake_run(cmd: list[str], **_: Any) -> int:
        commands.append(cmd)
        return 0

    def fake_output(cmd: list[str], **_: Any) -> str:
        if cmd == ["sudo", "podman", "ps", "--format", "{{.Names}}"]:
            return "systemd-postgres\n"
        return ""

    manager = RegistryManager(tmp_path, runner=fake_run, output_runner=fake_output, macos=False)

    def fake_request(method: str, url: str, payload: object | None = None) -> tuple[int, str]:
        requests.append((method, url, payload))
        if method == "GET" and url.endswith("/hsm/v2/Inventory/EthernetInterfaces"):
            body = json.dumps(
                [
                    {
                        "ID": "525400deadbe",
                        "MACAddress": "52:54:00:de:ad:be",
                        "ComponentID": "x0c0s0b0n0",
                        "IPAddresses": [{"IPAddress": "192.168.100.50"}],
                    },
                    {
                        "ID": "5254009e0a62",
                        "MACAddress": "52:54:00:9e:0a:62",
                        "ComponentID": "x0c0s0b0n0",
                        "IPAddresses": [{"IPAddress": "192.168.100.50"}],
                    },
                    {
                        "ID": "525400ec9a25",
                        "MACAddress": "52:54:00:ec:9a:25",
                        "ComponentID": "x0c0s1b0n0",
                        "IPAddresses": [{"IPAddress": "192.168.100.51"}],
                    },
                ]
            )
            return 200, body
        return 200, ""

    manager._request_json = fake_request  # type: ignore[method-assign]

    manager._register_node_with_endpoints(
        mac="52:54:00:9e:0a:62",
        ip="192.168.100.50",
        component_id="x0c0s0b0n0",
        nid=1,
        bmc_ip="192.168.100.2",
        bmc_user="root",
        bmc_pass="password",
        endpoints=ServiceEndpoints(smd_ip="192.168.100.2", bss_ip="192.168.100.2"),
        host_ip="192.168.100.2",
        orchestrator="quadlets",
        dry_run=False,
    )

    assert (
        "DELETE",
        "http://192.168.100.2:27779/hsm/v2/Inventory/EthernetInterfaces/525400deadbe",
        None,
    ) in requests
    assert (
        "DELETE",
        "http://192.168.100.2:27779/hsm/v2/Inventory/EthernetInterfaces/5254009e0a62",
        None,
    ) not in requests

    kea_sql_commands = [cmd for cmd in commands if cmd[:9] == ["sudo", "podman", "exec", "systemd-postgres", "psql", "-U", "kea-user", "-d", "kea"]]
    assert len(kea_sql_commands) == 1
    assert "DELETE FROM hosts" in kea_sql_commands[0][-1]
    assert "hostname = 'x0c0s0b0n0'" in kea_sql_commands[0][-1]
    assert "decode('5254009e0a62', 'hex')" in kea_sql_commands[0][-1]

    assert (
        "PUT",
        "http://192.168.100.2:27778/boot/v1/bootparameters",
        {
            "hosts": ["x0c0s0b0n0"],
            "kernel": "http://192.168.100.2:80/artifacts/opensuse/vmlinuz-lts",
            "initrd": "http://192.168.100.2:80/artifacts/opensuse/initramfs-lts",
            "params": "console=ttyS0 ip=dhcp rd.neednet=1 root=live:http://192.168.100.2:80/artifacts/opensuse/rootfs.squashfs",
        },
    ) in requests

    bss_sql_commands = [cmd for cmd in commands if cmd[:9] == ["sudo", "podman", "exec", "systemd-postgres", "psql", "-U", "bss-user", "-d", "bssdb"]]
    assert len(bss_sql_commands) == 1
    assert "DELETE FROM boot_group_assignments" in bss_sql_commands[0][-1]
    assert "COALESCE(n.xname, '') = ''" in bss_sql_commands[0][-1]
    assert "WHERE xname = 'x0c0s0b0n0'" in bss_sql_commands[0][-1]
    assert "UPDATE nodes SET boot_mac = '52:54:00:9e:0a:62', nid = 1 WHERE xname = 'x0c0s0b0n0'" in bss_sql_commands[0][-1]


def test_register_node_puts_ethernet_interface_on_conflict(tmp_path: Path) -> None:
    requests: list[tuple[str, str, object | None]] = []

    manager = RegistryManager(tmp_path, runner=lambda *_args, **_kwargs: 0, output_runner=lambda *_args, **_kwargs: "", macos=False)

    def fake_request(method: str, url: str, payload: object | None = None) -> tuple[int, str]:
        requests.append((method, url, payload))
        if method == "GET" and url.endswith("/hsm/v2/Inventory/EthernetInterfaces"):
            return 200, "[]"
        if method == "POST" and url.endswith("/hsm/v2/Inventory/EthernetInterfaces"):
            return 409, ""
        return 200, ""

    manager._request_json = fake_request  # type: ignore[method-assign]

    manager._register_node_with_endpoints(
        mac="52:54:00:9e:0a:62",
        ip="192.168.100.50",
        component_id="x0c0s0b0n0",
        nid=1,
        bmc_ip="192.168.100.2",
        bmc_user="root",
        bmc_pass="password",
        endpoints=ServiceEndpoints(smd_ip="192.168.100.2", bss_ip="192.168.100.2"),
        host_ip="192.168.100.2",
        orchestrator="docker-compose",
        dry_run=False,
    )

    assert (
        "PUT",
        "http://192.168.100.2:27779/hsm/v2/Inventory/EthernetInterfaces/5254009e0a62",
        {
            "Description": "Node NIC",
            "MACAddress": "52:54:00:9e:0a:62",
            "IPAddresses": [{"IPAddress": "192.168.100.50"}],
            "ComponentID": "x0c0s0b0n0",
        },
    ) in requests


def test_quadlets_secondary_vms_use_unique_redfish_ports(tmp_path: Path) -> None:
    manager = RegistryManager(tmp_path, macos=False)

    assert manager._emulator_ip(
        "virtual-compute-node-0",
        host_ip="192.168.100.2",
        orchestrator="quadlets",
        dry_run=False,
    ) == "192.168.100.2"
    assert manager._emulator_ip(
        "virtual-compute-node-1",
        host_ip="192.168.100.2",
        orchestrator="quadlets",
        dry_run=False,
    ) == "192.168.100.2:8444"
