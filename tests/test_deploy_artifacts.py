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


class TestHelmArtifacts:
    def test_values_yaml_exists(self):
        assert (PROJECT / "deploy" / "helm" / "values.yaml").is_file()

    def test_templates_dir_exists(self):
        assert (PROJECT / "deploy" / "helm" / "templates").is_dir()
