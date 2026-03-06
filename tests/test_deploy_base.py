from __future__ import annotations

from pathlib import Path

from ochami.defaults import DEFAULT_PORTS
from ochami.deploy.base import LOCALHOST_HEALTH_CHECKS, BaseDeployer


def test_health_check_list_count() -> None:
    assert len(LOCALHOST_HEALTH_CHECKS) == 5


def test_health_check_ports_match_defaults() -> None:
    for name, url in LOCALHOST_HEALTH_CHECKS:
        if name == "SMD":
            assert f":{DEFAULT_PORTS['SMD_PORT']}/" in url
        elif name == "BSS":
            assert f":{DEFAULT_PORTS['BSS_PORT']}/" in url
        elif name == "cloud-init":
            assert f":{DEFAULT_PORTS['CLOUD_INIT_PORT']}/" in url
        elif name == "PCS":
            assert f":{DEFAULT_PORTS['PCS_PORT']}/" in url
        elif name == "Stork":
            assert f":{DEFAULT_PORTS['STORK_PORT']}/" in url


def test_write_mcp_defaults_creates_file(tmp_path: Path) -> None:
    class FakeDeployer(BaseDeployer):
        def __init__(self, project_root: Path) -> None:
            self.project_root = project_root

        def configure_network(self, config, dry_run):
            return "127.0.0.1"

        def deploy(self, config, host_ip, dry_run):
            pass

        def post_deploy(self, config, host_ip, dry_run):
            pass

    deployer = FakeDeployer(tmp_path)
    deployer.write_mcp_defaults(host_ip="10.0.0.1", http_port=80, method_label="docker-compose", dry_run=False)

    mcp_path = tmp_path / ".openchami-mcp.env"
    assert mcp_path.is_file()
    content = mcp_path.read_text(encoding="utf-8")
    assert "OPENCHAMI_BASE_URL=http://10.0.0.1:80" in content
    assert "docker-compose" in content
    assert "OPENCHAMI_MCP_MODE=read-only" in content
    assert "OPENCHAMI_MCP_ENABLE_WRITES=false" in content


def test_write_mcp_defaults_dry_run_no_op(tmp_path: Path) -> None:
    class FakeDeployer(BaseDeployer):
        def __init__(self, project_root: Path) -> None:
            self.project_root = project_root

        def configure_network(self, config, dry_run):
            return "127.0.0.1"

        def deploy(self, config, host_ip, dry_run):
            pass

        def post_deploy(self, config, host_ip, dry_run):
            pass

    deployer = FakeDeployer(tmp_path)
    deployer.write_mcp_defaults(host_ip="10.0.0.1", http_port=80, method_label="docker-compose", dry_run=True)

    assert not (tmp_path / ".openchami-mcp.env").exists()


def test_write_mcp_defaults_method_label_variations(tmp_path: Path) -> None:
    class FakeDeployer(BaseDeployer):
        def __init__(self, project_root: Path) -> None:
            self.project_root = project_root

        def configure_network(self, config, dry_run):
            return "127.0.0.1"

        def deploy(self, config, host_ip, dry_run):
            pass

        def post_deploy(self, config, host_ip, dry_run):
            pass

    for label in ("docker-compose", "quadlets", "minikube"):
        deployer = FakeDeployer(tmp_path)
        deployer.write_mcp_defaults(host_ip="10.0.0.1", http_port=80, method_label=label, dry_run=False)
        content = (tmp_path / ".openchami-mcp.env").read_text(encoding="utf-8")
        assert label in content
