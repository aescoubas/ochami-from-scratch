"""Verify deployment artifacts exist and are valid."""
import pathlib
import pytest

PROJECT = pathlib.Path(__file__).resolve().parent.parent


class TestComposeArtifacts:
    def test_docker_compose_exists(self):
        assert (PROJECT / "deploy" / "compose" / "docker-compose.yml").is_file()

    def test_env_template_exists(self):
        assert (PROJECT / "deploy" / "compose" / ".env.template").is_file()

    def test_configs_exist(self):
        configs = PROJECT / "deploy" / "compose" / "configs"
        assert configs.is_dir()
        assert (configs / "nginx.conf").is_file()
        assert (configs / "kea-dhcp4.conf").is_file()

    def test_pg_init_exists(self):
        pg_init = PROJECT / "deploy" / "compose" / "pg-init"
        assert pg_init.is_dir()

    def test_kea_config_uses_template_vars(self):
        content = (PROJECT / "deploy" / "compose" / "configs" / "kea-dhcp4.conf").read_text()
        assert "KEA_DB_PASSWORD" in content, "Kea config should use template variable, not hardcoded secret"


class TestQuadletArtifacts:
    def test_containers_dir_exists(self):
        assert (PROJECT / "deploy" / "quadlets" / "containers").is_dir()

    def test_configs_dir_exists(self):
        assert (PROJECT / "deploy" / "quadlets" / "configs").is_dir()

    def test_rustfs_quadlet_exists(self):
        rustfs = PROJECT / "deploy" / "quadlets" / "containers" / "rustfs.container"
        assert rustfs.is_file()

    def test_openchami_mcp_quadlet_exists(self):
        mcp = PROJECT / "deploy" / "quadlets" / "containers" / "openchami-mcp.container"
        assert mcp.is_file()

    def test_openchami_target_includes_rustfs_and_mcp(self):
        content = (PROJECT / "deploy" / "quadlets" / "containers" / "openchami.target").read_text()
        assert "rustfs.service" in content
        assert "openchami-mcp.service" in content

    def test_kea_sync_quadlet_pins_release_image(self):
        content = (PROJECT / "deploy" / "quadlets" / "containers" / "kea-sync.container").read_text()
        assert "Image=jfrog.svc.cscs.ch/docker/openchami/cscs-kea-sync:v0.1.0" in content
        assert "Exec=/usr/local/bin/kea-sync" in content

    def test_openchami_mcp_quadlet_uses_release_image_and_http_mode(self):
        content = (PROJECT / "deploy" / "quadlets" / "containers" / "openchami-mcp.container").read_text()
        assert "Image=jfrog.svc.cscs.ch/docker/openchami/cscs-openchami-mcp:v0.1.1" in content
        assert "OPENCHAMI_MCP_MODE=read-write" in content
        assert "OPENCHAMI_MCP_ENABLE_WRITES=true" in content
        assert "OPENCHAMI_MCP_TRANSPORT=http" in content
        assert "OPENCHAMI_MCP_LISTEN_ADDR=127.0.0.1:8081" in content
        assert "OPENCHAMI_MCP_BASE_PATH=/mcp" in content
        assert "OPENCHAMI_MCP_HEALTH_PATH=/healthz" in content
        assert "OPENCHAMI_MCP_SMD_URL=https://localhost:27779" in content
        assert "OPENCHAMI_MCP_SMD_TLS_INSECURE_SKIP_VERIFY=true" in content
        assert "OPENCHAMI_MCP_POWER_CONTROL_URL=http://localhost:28007/v1" in content
        assert "HealthCmd=curl -sf http://127.0.0.1:8081/healthz" in content
        assert "Exec=" not in content

    def test_quadlet_env_template_includes_rustfs_credentials(self):
        content = (PROJECT / "deploy" / "quadlets" / ".env.template").read_text()
        assert "RUSTFS_ACCESS_KEY=" in content
        assert "RUSTFS_SECRET_KEY=" in content

    def test_rustfs_uses_shared_artifacts_root(self):
        content = (PROJECT / "deploy" / "quadlets" / "containers" / "rustfs.container").read_text()
        assert "/etc/openchami/artifacts:/srv/openchami-artifacts" in content
        assert "RUSTFS_VOLUMES=/srv/openchami-artifacts/rustfs-data" in content

    def test_rustfs_request_logging_enabled(self):
        content = (PROJECT / "deploy" / "quadlets" / "containers" / "rustfs.container").read_text()
        assert "RUSTFS_OBS_LOGGER_LEVEL=warn" in content
        assert "RUST_LOG=warn,rustfs::server::http=debug" in content
        assert "RUSTFS_OBS_USE_STDOUT=true" in content
        assert "RUSTFS_OBS_LOG_STDOUT_ENABLED=true" in content


class TestHelmArtifacts:
    def test_values_yaml_exists(self):
        assert (PROJECT / "deploy" / "helm" / "values.yaml").is_file()

    def test_templates_dir_exists(self):
        assert (PROJECT / "deploy" / "helm" / "templates").is_dir()
