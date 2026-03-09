from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from ochami.build import BuildManager, sanitize_tag
from ochami.config import DeployConfig, DeploymentMethod


def test_sanitize_tag_replaces_slashes() -> None:
    assert sanitize_tag("feature/smd-fast-path") == "feature-smd-fast-path"


def test_build_bss_retries_make_binaries(tmp_path: Path) -> None:
    repo_dir = tmp_path / "repo"
    repo_dir.mkdir()

    calls: list[tuple[list[str], Path | None]] = []
    attempts = {"make_binaries": 0}
    sleeps: list[float] = []

    def fake_run(cmd: list[str], **kwargs: Any) -> int:
        cwd = kwargs.get("cwd")
        calls.append((cmd, cwd))
        if cmd == ["make", "binaries"]:
            attempts["make_binaries"] += 1
            if attempts["make_binaries"] == 1:
                raise RuntimeError("transient failure")
        return 0

    manager = BuildManager(
        project_root=tmp_path,
        runner=fake_run,
        output_runner=lambda _cmd, **_kwargs: "",
        sleeper=lambda seconds: sleeps.append(seconds),
        env={"BUILD_RETRY_ATTEMPTS": "3", "BUILD_RETRY_DELAY_SECONDS": "0"},
    )
    manager._prepare_repo = lambda **_kwargs: repo_dir  # type: ignore[method-assign]

    cfg = DeployConfig(
        method=DeploymentMethod.DOCKER_COMPOSE,
        bss_ref="main",
        bss_repo_uri="https://github.com/openchami/bss.git",
    )
    manager.build_bss(config=cfg, container_tool="docker", dry_run=False)

    assert attempts["make_binaries"] == 2
    assert sleeps == [0]
    assert any(cmd == ["docker", "build", "-t", "localhost/bss:local-bss", "."] for cmd, _ in calls)


def test_build_images_if_needed_invokes_expected_build_steps(tmp_path: Path) -> None:
    manager = BuildManager(
        project_root=tmp_path,
        runner=lambda _cmd, **_kwargs: 0,
        output_runner=lambda _cmd, **_kwargs: "",
    )
    cfg = DeployConfig(method=DeploymentMethod.DOCKER_COMPOSE)

    events: list[str] = []
    manager._image_exists = lambda _image, **_kwargs: False  # type: ignore[method-assign]
    manager._build_artifacts_and_core_images = lambda **_kwargs: events.append("artifacts")  # type: ignore[method-assign]
    manager._build_local_image = lambda **_kwargs: events.append("local-image")  # type: ignore[method-assign]
    manager._load_into_minikube_if_needed = lambda *_args, **_kwargs: None  # type: ignore[method-assign]
    manager.build_smd = lambda **_kwargs: events.append("smd")  # type: ignore[method-assign]
    manager.build_bss = lambda **_kwargs: events.append("bss")  # type: ignore[method-assign]
    manager.build_pcs = lambda **_kwargs: events.append("pcs")  # type: ignore[method-assign]
    manager.build_cloud_init = lambda **_kwargs: events.append("cloud_init")  # type: ignore[method-assign]

    manager.build_images_if_needed(
        cfg,
        orchestrator="docker-compose",
        container_tool="docker",
        force_rebuild=False,
        dry_run=False,
    )

    assert events.count("artifacts") == 1
    assert events.count("local-image") == 3
    assert "smd" in events and "bss" in events and "pcs" in events and "cloud_init" in events


def test_build_images_if_needed_rebuilds_core_artifacts_when_missing(tmp_path: Path) -> None:
    manager = BuildManager(
        project_root=tmp_path,
        runner=lambda _cmd, **_kwargs: 0,
        output_runner=lambda _cmd, **_kwargs: "",
    )
    cfg = DeployConfig(method=DeploymentMethod.QUADLETS)

    events: list[str] = []
    manager._image_exists = lambda _image, **_kwargs: True  # type: ignore[method-assign]
    manager._build_artifacts_and_core_images = lambda **_kwargs: events.append("artifacts")  # type: ignore[method-assign]
    manager._build_local_image = lambda **_kwargs: events.append("local-image")  # type: ignore[method-assign]
    manager._load_into_minikube_if_needed = lambda *_args, **_kwargs: None  # type: ignore[method-assign]
    manager.build_smd = lambda **_kwargs: events.append("smd")  # type: ignore[method-assign]
    manager.build_bss = lambda **_kwargs: events.append("bss")  # type: ignore[method-assign]
    manager.build_pcs = lambda **_kwargs: events.append("pcs")  # type: ignore[method-assign]
    manager.build_cloud_init = lambda **_kwargs: events.append("cloud_init")  # type: ignore[method-assign]

    manager.build_images_if_needed(
        cfg,
        orchestrator="quadlets",
        container_tool="sudo podman",
        force_rebuild=False,
        dry_run=False,
    )

    assert events == ["artifacts"]


def test_copy_artifact_from_container_normalizes_permissions(tmp_path: Path) -> None:
    calls: list[list[str]] = []

    def fake_run(cmd: list[str], **_kwargs: Any) -> int:
        calls.append(cmd)
        return 0

    manager = BuildManager(
        project_root=tmp_path,
        runner=fake_run,
        output_runner=lambda _cmd, **_kwargs: "",
    )

    manager._copy_artifact_from_container(
        "sudo podman",
        "abc123",
        "/boot/initrd.img",
        tmp_path / "initramfs-lts",
        dry_run=False,
    )

    assert calls == [
        ["sudo", "podman", "cp", "abc123:/boot/initrd.img", str(tmp_path / "initramfs-lts")],
        ["sudo", "chown", "-R", f"{os.getuid()}:{os.getgid()}", str(tmp_path / "initramfs-lts")],
        ["chmod", "-R", "u+rwX,go+rX", str(tmp_path / "initramfs-lts")],
    ]


def test_unpinned_base_image_fallback_for_missing_registry_digest(tmp_path: Path) -> None:
    manager = BuildManager(
        project_root=tmp_path,
        runner=lambda _cmd, **_kwargs: 0,
        output_runner=lambda _cmd, **_kwargs: "",
    )

    fallback = manager._fallback_unpinned_base_image(  # type: ignore[attr-defined]
        "opensuse/leap:15.6@sha256:deadbeef",
        RuntimeError(
            "failed to solve: failed to resolve source metadata for "
            "docker.io/opensuse/leap:15.6@sha256:deadbeef: not found"
        ),
    )

    assert fallback == "opensuse/leap:15.6"


def test_unpinned_base_image_fallback_ignores_non_registry_errors(tmp_path: Path) -> None:
    manager = BuildManager(
        project_root=tmp_path,
        runner=lambda _cmd, **_kwargs: 0,
        output_runner=lambda _cmd, **_kwargs: "",
    )

    fallback = manager._fallback_unpinned_base_image(  # type: ignore[attr-defined]
        "opensuse/leap:15.6@sha256:deadbeef",
        RuntimeError("permission denied"),
    )

    assert fallback is None
