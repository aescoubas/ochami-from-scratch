from __future__ import annotations

from collections.abc import Sequence
import re
from pathlib import Path
import shutil

from ochami.utils import run, run_output


FS_PROTECTED_REGULAR_STATE_FILE = Path("/tmp/openchami-fs-protected-regular.state")
_VM_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")


def relax_permissions(paths: Sequence[Path], *, runner=run, dry_run: bool) -> None:
    for path in paths:
        runner(["sudo", "chmod", "-R", "a+rwX", str(path)], dry_run=dry_run, check=False)


def destroy_vms(
    vm_name: str,
    *,
    runner=run,
    output_runner=run_output,
    dry_run: bool,
    macos: bool,
) -> None:
    if macos:
        return
    if not _VM_NAME_PATTERN.fullmatch(vm_name):
        raise ValueError(f"unsafe vm_name pattern: {vm_name!r}")

    listing = output_runner(["sudo", "virsh", "list", "--all", "--name"], dry_run=dry_run, check=False)
    targets = [line.strip() for line in listing.splitlines() if line.strip()]
    matched = [name for name in targets if name == vm_name or name.startswith(f"{vm_name}-")]

    for name in matched:
        runner(["sudo", "virsh", "destroy", name], dry_run=dry_run, check=False)
        runner(["sudo", "virsh", "undefine", "--nvram", name], dry_run=dry_run, check=False)


def cleanup_build_artifacts(project_root: Path, *, dry_run: bool) -> None:
    artifacts_root = project_root / "images"
    for path in (
        artifacts_root / "opensuse",
        artifacts_root / "ubuntu",
        artifacts_root / "vmlinuz-lts",
        artifacts_root / "initramfs-lts",
        artifacts_root / "rootfs.squashfs",
    ):
        if not path.exists() or dry_run:
            continue
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()


def lower_fs_protected_regular_if_needed(
    *,
    runner=run,
    output_runner=run_output,
    fs_state_path: Path = FS_PROTECTED_REGULAR_STATE_FILE,
    dry_run: bool,
    macos: bool,
) -> bool:
    if macos:
        return False

    current = output_runner(["sysctl", "-n", "fs.protected_regular"], dry_run=dry_run, check=False).strip()
    if not current or current == "0":
        return False

    rc = runner(["sudo", "sysctl", "-w", "fs.protected_regular=0"], dry_run=dry_run, check=False)
    if rc != 0:
        return False

    verified = output_runner(["sysctl", "-n", "fs.protected_regular"], dry_run=dry_run, check=False).strip()
    if verified != "0":
        return False

    if not dry_run:
        fs_state_path.parent.mkdir(parents=True, exist_ok=True)
        fs_state_path.write_text(current + "\n", encoding="utf-8")
    return True


def restore_fs_protected_regular_if_managed(
    *,
    runner=run,
    output_runner=run_output,
    fs_state_path: Path = FS_PROTECTED_REGULAR_STATE_FILE,
    dry_run: bool,
    macos: bool,
) -> None:
    if macos:
        return
    if not fs_state_path.is_file():
        return

    previous_value = fs_state_path.read_text(encoding="utf-8").strip()
    if not previous_value.isdigit():
        if not dry_run:
            fs_state_path.unlink(missing_ok=True)
        return

    current = output_runner(["sysctl", "-n", "fs.protected_regular"], dry_run=dry_run, check=False).strip()
    if not current:
        return

    if current == previous_value:
        if not dry_run:
            fs_state_path.unlink(missing_ok=True)
        return

    rc = runner(["sudo", "sysctl", "-w", f"fs.protected_regular={previous_value}"], dry_run=dry_run, check=False)
    if rc == 0 and not dry_run:
        fs_state_path.unlink(missing_ok=True)
