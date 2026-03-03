from __future__ import annotations

from pathlib import Path

from ochami.templates import TemplateRenderer


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def test_render_kea_template_preserves_ipxe_mac_placeholder() -> None:
    renderer = TemplateRenderer(_repo_root() / "templates")

    content = renderer.render(
        "compose/kea-dhcp4.conf.j2",
        {
            "pxe_interface": "virbr-pxe",
            "kea_db_name": "kea",
            "kea_db_user": "kea-user",
            "kea_db_password": "secret",
            "postgres_port": 5432,
            "host_ip": "192.168.100.2",
            "http_port": 80,
            "dhcp_start": "192.168.100.100",
            "dhcp_end": "192.168.100.200",
            "pxe_cidr": 24,
        },
    )

    assert '"interfaces": ["virbr-pxe"]' in content
    assert "bootscript?mac=${mac}" in content
    assert '"pool": "192.168.100.100 - 192.168.100.200"' in content


def test_render_boot_template() -> None:
    renderer = TemplateRenderer(_repo_root() / "templates")

    content = renderer.render(
        "compose/boot.ipxe.j2",
        {
            "host_ip": "10.1.2.3",
            "http_port": 8080,
        },
    )

    assert "Server: 10.1.2.3:8080" in content
    assert "set base-url http://10.1.2.3:8080" in content
