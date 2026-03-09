from __future__ import annotations


def vm_index_from_name(vm_name: str) -> int | None:
    suffix = vm_name.rsplit("-", 1)[-1]
    if not suffix.isdigit():
        return None
    return int(suffix)


def quadlet_redfish_port(vm_index: int) -> int:
    if vm_index <= 0:
        return 443
    return 8443 + vm_index


def quadlet_redfish_host(host_ip: str, vm_index: int) -> str:
    port = quadlet_redfish_port(vm_index)
    if port == 443:
        return host_ip
    return f"{host_ip}:{port}"
