"""Integration-level validation of rendered configs and container units.

Structural tests always run; tool-dependent tests are skipped when the
required binary is not installed.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from ochami.templates import TemplateRenderer

_REPO_ROOT = Path(__file__).resolve().parent.parent


def _renderer() -> TemplateRenderer:
    return TemplateRenderer(_REPO_ROOT / "templates")


def _sample_context() -> dict[str, object]:
    return {
        "host_ip": "192.168.100.1",
        "pxe_interface": "virbr-pxe",
        "pxe_cidr": 24,
        "dhcp_start": "192.168.100.100",
        "dhcp_end": "192.168.100.200",
        "dhcp_netmask": "255.255.255.0",
        "http_port": 80,
        "smd_port": 27779,
        "bss_port": 27778,
        "postgres_port": 5432,
        "cloud_init_port": 27777,
        "pcs_port": 28007,
        "stork_port": 28010,
        "stork_agent_port": 28011,
        "kea_db_name": "kea",
        "kea_db_user": "kea-user",
        "kea_db_password": "secret",
        "stork_db_name": "stork",
        "stork_db_user": "stork-user",
        "stork_db_password": "secret",
        "pcs_db_name": "pcsdb",
        "pcs_db_user": "pcs-user",
        "pcs_db_password": "secret",
    }


# ------------------------------------------------------------------
# Structural validation (always runs)
# ------------------------------------------------------------------

def test_rendered_kea_config_is_valid_json() -> None:
    content = _renderer().render("shared/kea-dhcp4.conf.j2", _sample_context())
    parsed = json.loads(content)
    assert "Dhcp4" in parsed
    assert "interfaces-config" in parsed["Dhcp4"]
    assert "subnet4" in parsed["Dhcp4"]
    assert "lease-database" in parsed["Dhcp4"]


def test_rendered_stork_env_has_required_keys() -> None:
    content = _renderer().render("shared/stork-server.env.j2", _sample_context())
    required = [
        "STORK_DATABASE_HOST",
        "STORK_DATABASE_PORT",
        "STORK_DATABASE_NAME",
        "STORK_DATABASE_USER_NAME",
        "STORK_DATABASE_PASSWORD",
        "STORK_SERVER_PORT",
    ]
    for key in required:
        assert key in content, f"missing key: {key}"


def test_rendered_nginx_has_all_proxy_locations() -> None:
    content = _renderer().render("shared/nginx-default.conf.j2", _sample_context())
    expected_locations = ["/boot/v1/", "/hsm/", "/cloud-init/", "/power-control/", "/stork/", "/api/"]
    for loc in expected_locations:
        assert loc in content, f"missing location: {loc}"


def test_rendered_boot_ipxe_has_kernel_and_initrd() -> None:
    content = _renderer().render("shared/boot.ipxe.j2", _sample_context())
    assert "kernel" in content.lower() or "kernel" in content
    assert "initrd" in content.lower() or "initrd" in content
    assert "${base-url}" in content


def test_quadlet_container_files_have_required_sections() -> None:
    containers_dir = _REPO_ROOT / "ochami-quadlets" / "containers"
    container_files = sorted(containers_dir.glob("*.container"))
    assert len(container_files) >= 16, f"expected >=16 .container files, found {len(container_files)}"

    for path in container_files:
        content = path.read_text(encoding="utf-8")
        for section in ("[Unit]", "[Container]", "[Service]", "[Install]"):
            assert section in content, f"{path.name} missing {section}"


# ------------------------------------------------------------------
# Conditional tests (skip when tool not installed)
# ------------------------------------------------------------------

@pytest.mark.skipif(not shutil.which("docker"), reason="docker not installed")
def test_docker_compose_config_valid(tmp_path: Path) -> None:
    compose_dir = _REPO_ROOT / "ochami-docker-compose"
    compose_file = compose_dir / "docker-compose.yml"
    if not compose_file.is_file():
        pytest.skip("docker-compose.yml not found")

    env_file = tmp_path / ".env"
    env_lines = [
        "HOST_IP=192.168.100.1",
        "PXE_INTERFACE=virbr-pxe",
        "PXE_CIDR=24",
        "DHCP_START=192.168.100.100",
        "DHCP_END=192.168.100.200",
        "DHCP_NETMASK=255.255.255.0",
        "HTTP_PORT=80",
        "SMD_PORT=27779",
        "BSS_PORT=27778",
        "POSTGRES_PORT=5432",
        "POSTGRES_USER=ochami",
        "POSTGRES_PASSWORD=test",
        "SMD_DB_NAME=hmsds",
        "SMD_DB_USER=smd-user",
        "SMD_DB_PASSWORD=test",
        "BSS_DB_NAME=bssdb",
        "BSS_DB_USER=bss-user",
        "BSS_DB_PASSWORD=test",
        "KEA_DB_NAME=kea",
        "KEA_DB_USER=kea-user",
        "KEA_DB_PASSWORD=test",
        "HYDRA_DB_PASSWORD=test",
        "CLOUD_INIT_PORT=27777",
        "PCS_DB_NAME=pcsdb",
        "PCS_DB_USER=pcs-user",
        "PCS_DB_PASSWORD=test",
        "PCS_PORT=28007",
        "STORK_DB_NAME=stork",
        "STORK_DB_USER=stork-user",
        "STORK_DB_PASSWORD=test",
        "STORK_PORT=28010",
        "STORK_AGENT_PORT=28011",
        "NUM_VMS=0",
        "PROJECT_ROOT=/tmp/test",
    ]
    env_file.write_text("\n".join(env_lines) + "\n", encoding="utf-8")

    result = subprocess.run(
        ["docker", "compose", "-f", str(compose_file), "--env-file", str(env_file), "config", "--quiet"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"docker compose config failed:\n{result.stderr}"


@pytest.mark.skipif(not shutil.which("helm"), reason="helm not installed")
def test_helm_template_valid() -> None:
    helm_dir = _REPO_ROOT / "ochami-helm"
    values_file = helm_dir / "values-pxe.yaml"
    if not helm_dir.is_dir() or not values_file.is_file():
        pytest.skip("helm chart or values-pxe.yaml not found")

    result = subprocess.run(
        ["helm", "template", "test-release", str(helm_dir), "-f", str(values_file)],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"helm template failed:\n{result.stderr}"
