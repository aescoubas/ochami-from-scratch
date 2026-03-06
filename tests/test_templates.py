from __future__ import annotations

from pathlib import Path

from ochami.templates import TemplateRenderer


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def test_render_kea_template_preserves_ipxe_mac_placeholder() -> None:
    renderer = TemplateRenderer(_repo_root() / "templates")

    content = renderer.render(
        "shared/kea-dhcp4.conf.j2",
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
        "shared/boot.ipxe.j2",
        {
            "host_ip": "10.1.2.3",
            "http_port": 8080,
        },
    )

    assert "Server: 10.1.2.3:8080" in content
    assert "set base-url http://10.1.2.3:8080" in content


def test_render_stork_template() -> None:
    renderer = TemplateRenderer(_repo_root() / "templates")

    content = renderer.render(
        "shared/stork-server.env.j2",
        {
            "postgres_port": 5432,
            "stork_db_name": "stork",
            "stork_db_user": "stork-user",
            "stork_db_password": "secret",
            "stork_port": 28010,
        },
    )

    assert "STORK_DATABASE_NAME=stork" in content
    assert "STORK_DATABASE_USER_NAME=stork-user" in content
    assert "STORK_SERVER_PORT=28010" in content


def test_render_nginx_template() -> None:
    renderer = TemplateRenderer(_repo_root() / "templates")

    content = renderer.render(
        "shared/nginx-default.conf.j2",
        {
            "http_port": 80,
            "bss_port": 27778,
            "smd_port": 27779,
            "cloud_init_port": 27777,
            "pcs_port": 28007,
            "stork_port": 28010,
        },
    )

    assert "listen       80;" in content
    assert "/boot/v1/" in content
    assert "/hsm/" in content
    assert "/cloud-init/" in content
    assert "/power-control/" in content
    assert "/stork/" in content
