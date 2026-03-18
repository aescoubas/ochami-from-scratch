"""Tests for nix/generators/*.nix — verify generator files exist and flake exports them."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class TestGeneratorFilesExist:
    """All generator Nix files must be present."""

    def test_docker_compose_generator_exists(self):
        assert (ROOT / "nix" / "generators" / "docker-compose.nix").is_file()

    def test_quadlets_generator_exists(self):
        assert (ROOT / "nix" / "generators" / "quadlets.nix").is_file()

    def test_helm_values_generator_exists(self):
        assert (ROOT / "nix" / "generators" / "helm-values.nix").is_file()


class TestFlakeExportsGenerators:
    """Verify flake.nix references all three generators."""

    def setup_method(self):
        self.flake = (ROOT / "flake.nix").read_text()

    def test_flake_exports_docker_compose_yml(self):
        assert "docker-compose-yml" in self.flake

    def test_flake_exports_quadlet_units(self):
        assert "quadlet-units" in self.flake

    def test_flake_exports_helm_values(self):
        assert "helm-values" in self.flake

    def test_flake_exports_boot_artifacts(self):
        assert "boot-artifacts" in self.flake

    def test_flake_references_generator_paths(self):
        assert "nix/generators/docker-compose.nix" in self.flake
        assert "nix/generators/quadlets.nix" in self.flake
        assert "nix/generators/helm-values.nix" in self.flake
        assert "nix/boot-artifacts.nix" in self.flake


class TestDockerComposeGenerator:
    """Structural checks on docker-compose.nix."""

    def setup_method(self):
        self.content = (ROOT / "nix" / "generators" / "docker-compose.nix").read_text()

    def test_imports_all_service_modules(self):
        assert "../services/catalog.nix" in self.content
        assert "profile" in self.content

    def test_collects_all_services(self):
        assert "stack.allContainerServices" in self.content
        assert "kea.controlAgent" not in self.content

    def test_generates_depends_on(self):
        assert "depends_on" in self.content
        assert "service_completed_successfully" in self.content
        assert "service_healthy" in self.content

    def test_generates_healthcheck(self):
        assert "healthcheck" in self.content
        assert "CMD-SHELL" in self.content

    def test_handles_network_mode_host(self):
        assert "network_mode: host" in self.content

    def test_handles_volumes(self):
        assert "volumes" in self.content

    def test_handles_capabilities(self):
        assert "cap_add" in self.content

    def test_defaults_to_virbr_ochami_interface(self):
        assert 'pxeInterface ? "virbr-ochami"' in self.content


class TestQuadletsGenerator:
    """Structural checks on quadlets.nix."""

    def setup_method(self):
        self.content = (ROOT / "nix" / "generators" / "quadlets.nix").read_text()

    def test_imports_all_service_modules(self):
        assert "../services/catalog.nix" in self.content
        assert "profile" in self.content

    def test_generates_container_section(self):
        assert "[Container]" in self.content

    def test_generates_unit_section(self):
        assert "[Unit]" in self.content

    def test_generates_install_section(self):
        assert "[Install]" in self.content
        assert "openchami.target" in self.content

    def test_handles_environment_file(self):
        assert "EnvironmentFile=/etc/openchami/openchami.env" in self.content

    def test_handles_capabilities(self):
        assert "AddCapability" in self.content

    def test_handles_health_checks(self):
        assert "HealthCmd" in self.content
        assert "HealthInterval" in self.content

    def test_generates_target(self):
        assert "openchami.target" in self.content

    def test_defaults_to_virbr_ochami_interface(self):
        assert 'pxeInterface ? "virbr-ochami"' in self.content


class TestHelmValuesGenerator:
    """Structural checks on helm-values.nix."""

    def setup_method(self):
        self.content = (ROOT / "nix" / "generators" / "helm-values.nix").read_text()

    def test_uses_defaults_ports(self):
        assert "defaults.ports" in self.content

    def test_uses_defaults_databases(self):
        assert "defaults.databases" in self.content

    def test_generates_yaml_output(self):
        assert "yq" in self.content

    def test_has_all_service_sections(self):
        for svc in ["smd", "bss", "pcs", "kea", "cloudInit", "httpServer", "tftp", "stork"]:
            assert svc in self.content, f"helm-values.nix should reference {svc}"


class TestDefaultsNixLocalImages:
    """Verify defaults.nix keeps shared constants only."""

    def setup_method(self):
        self.content = (ROOT / "nix" / "services" / "defaults.nix").read_text()

    def test_keeps_upstream_images(self):
        assert "images" in self.content

    def test_does_not_embed_local_image_overrides(self):
        assert "localImages" not in self.content
        assert "localImageOverrides" not in self.content

    def test_has_base_images(self):
        assert "baseImages" in self.content

    def test_has_repos(self):
        assert "repos" in self.content
        for svc in ["smd", "bss", "pcs", "cloudInit", "keaSync"]:
            assert svc in self.content


class TestGeneratorsAcceptImageOverrides:
    """All generators must accept imageOverrides parameter."""

    def test_docker_compose_accepts_image_overrides(self):
        content = (ROOT / "nix" / "generators" / "docker-compose.nix").read_text()
        assert "imageOverrides" in content

    def test_quadlets_accepts_image_overrides(self):
        content = (ROOT / "nix" / "generators" / "quadlets.nix").read_text()
        assert "imageOverrides" in content

    def test_deploy_profile_accepts_image_overrides(self):
        content = (ROOT / "nix" / "deploy" / "profile.nix").read_text()
        assert "imageOverrides" in content
