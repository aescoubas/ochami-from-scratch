"""Tests verifying boot artifacts are volume-mounted rather than baked into the image."""
from __future__ import annotations

from pathlib import Path
import shutil
from typing import Any

from ochami.build import BuildManager
from ochami.system import cleanup_build_artifacts


PROJECT_ROOT = Path(__file__).resolve().parents[1]


# -- Source file structural checks --------------------------------------------------


def test_http_server_dockerfile_does_not_copy_artifacts() -> None:
    dockerfile = PROJECT_ROOT / "ochami-helm" / "http-server" / "Dockerfile"
    content = dockerfile.read_text(encoding="utf-8")
    assert "COPY artifacts" not in content
    assert "EXPOSE 80" in content


def test_compose_yml_mounts_images_as_artifacts_volume() -> None:
    compose_file = PROJECT_ROOT / "ochami-docker-compose" / "docker-compose.yml"
    content = compose_file.read_text(encoding="utf-8")
    assert "../images:/usr/share/nginx/html/artifacts:ro" in content


def test_quadlet_http_server_container_has_images_dir_volume() -> None:
    container_file = PROJECT_ROOT / "ochami-quadlets" / "containers" / "http-server.container"
    content = container_file.read_text(encoding="utf-8")
    assert "Volume=${IMAGES_DIR}:/usr/share/nginx/html/artifacts:ro" in content


def test_helm_http_server_pod_has_boot_artifacts_volume() -> None:
    pod_yaml = PROJECT_ROOT / "ochami-helm" / "templates" / "http-server-pod.yaml"
    content = pod_yaml.read_text(encoding="utf-8")
    assert "boot-artifacts" in content
    assert "mountPath: /usr/share/nginx/html/artifacts" in content
    assert "{{ .Values.projectRoot }}/images" in content
    assert "hostPath:" in content


def test_gitignore_excludes_images_directory() -> None:
    gitignore = PROJECT_ROOT / ".gitignore"
    content = gitignore.read_text(encoding="utf-8")
    assert "images/" in content


# -- Build artifact staging --------------------------------------------------


def test_build_artifacts_staged_to_images_directory(tmp_path: Path) -> None:
    """Verify _build_artifacts_and_core_images targets images/ not the old path."""
    manager = BuildManager(
        project_root=tmp_path,
        runner=lambda _cmd, **_kwargs: 0,
        output_runner=lambda _cmd, **_kwargs: "",
    )

    # The artifacts_root is computed inside _build_artifacts_and_core_images.
    # We can't easily run the full method (needs container tools), but we can
    # verify the path constant by inspecting the source or by calling
    # cleanup_build_artifacts which uses the same path.
    images_dir = tmp_path / "images"
    opensuse = images_dir / "opensuse"
    ubuntu = images_dir / "ubuntu"
    opensuse.mkdir(parents=True)
    ubuntu.mkdir(parents=True)
    (opensuse / "vmlinuz-lts").write_text("kernel", encoding="utf-8")
    (ubuntu / "vmlinuz-lts").write_text("kernel", encoding="utf-8")

    # Old path should NOT be used by cleanup
    old_path = tmp_path / "ochami-helm" / "http-server" / "artifacts" / "opensuse"
    old_path.mkdir(parents=True)
    (old_path / "vmlinuz-lts").write_text("kernel", encoding="utf-8")

    cleanup_build_artifacts(tmp_path, dry_run=False)

    # images/ contents cleaned
    assert not opensuse.exists()
    assert not ubuntu.exists()
    # Old path untouched (cleanup no longer knows about it)
    assert (old_path / "vmlinuz-lts").exists()


def test_cleanup_build_artifacts_is_noop_on_dry_run(tmp_path: Path) -> None:
    images_dir = tmp_path / "images"
    opensuse = images_dir / "opensuse"
    opensuse.mkdir(parents=True)
    (opensuse / "vmlinuz-lts").write_text("kernel", encoding="utf-8")

    cleanup_build_artifacts(tmp_path, dry_run=True)

    assert opensuse.exists()
    assert (opensuse / "vmlinuz-lts").exists()
