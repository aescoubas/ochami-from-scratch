from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_flake_exports_vm_lab_targets() -> None:
    flake = (PROJECT_ROOT / "flake.nix").read_text(encoding="utf-8")
    lab_test = (PROJECT_ROOT / "nix" / "tests" / "lab-smoke.nix").read_text(encoding="utf-8")

    assert "lab-smoke" in flake
    assert "lab-driver" in flake
    assert "lab-controller-vm" in flake
    assert "lab-boot-node-vm" in flake
    assert "testers.nixosTest" in lab_test
    assert "controller" in lab_test
    assert "bootnode" in lab_test


def test_lab_vm_modules_exist() -> None:
    controller = PROJECT_ROOT / "nix" / "lab" / "controller.nix"
    bootnode = PROJECT_ROOT / "nix" / "lab" / "boot-node.nix"
    systems = PROJECT_ROOT / "nix" / "lab" / "systems.nix"

    assert controller.exists()
    assert bootnode.exists()
    assert systems.exists()


def test_readme_documents_controller_vm_artifacts() -> None:
    readme = (PROJECT_ROOT / "README.md").read_text(encoding="utf-8")

    assert "build-lab-controller-vm" in readme
    assert "build-lab-boot-node-vm" in readme
    assert "make deploy METHOD=lab-vm" in readme
    assert "make create-test-vms METHOD=lab-vm" in readme
    assert "ochami-test-node-0-x1000c0s0b0n0.serial.log" in readme


def test_controller_vm_supports_standalone_host_access() -> None:
    controller = (PROJECT_ROOT / "nix" / "lab" / "controller.nix").read_text(encoding="utf-8")

    assert 'services.openssh' in controller
    assert '"10-eth0"' in controller
    assert 'DHCP = "ipv4"' in controller


def test_controller_vm_activates_in_guest_openchami_profile() -> None:
    controller = (PROJECT_ROOT / "nix" / "lab" / "controller.nix").read_text(encoding="utf-8")

    assert '"openchami/secrets.env".source = labSecrets' in controller
    assert "diskSize = 16384;" in controller
    assert "openchami-lab-load-images" in controller
    assert "podman image exists" in controller
    assert "podman load -i" in controller
    assert "openchami-lab-activate" in controller
    assert "labDeployProfile" in controller
    assert "systemd.packages = [ labDeployProfile ]" in controller
    assert 'systemctl start ochami.target' in controller


def test_lab_systems_use_local_image_overrides_for_controller_services() -> None:
    systems = (PROJECT_ROOT / "nix" / "lab" / "systems.nix").read_text(encoding="utf-8")

    assert "resolvedOfficialProfile" in systems
    assert "labProfile.imageOverrides" in systems
    assert "profile = labProfile;" in systems
    assert "labLocalImageArchives" in systems
    assert 'id != "kea-sync"' in systems


def test_lab_systems_do_not_pass_pkgs_to_plain_nix_services() -> None:
    """kea.nix and nginx.nix no longer take pkgs; systems.nix should not pass it."""
    systems = (PROJECT_ROOT / "nix" / "lab" / "systems.nix").read_text(encoding="utf-8")

    # labKea and labNginx calls should not contain 'pkgs ='
    import re
    kea_block = re.search(r'labKea = import.*?;$', systems, re.DOTALL | re.MULTILINE)
    nginx_block = re.search(r'labNginx = import.*?;$', systems, re.DOTALL | re.MULTILINE)
    assert kea_block is not None
    assert nginx_block is not None
    assert "pkgs =" not in kea_block.group()
    assert "pkgs =" not in nginx_block.group()


def test_lab_systems_set_state_version() -> None:
    systems = (PROJECT_ROOT / "nix" / "lab" / "systems.nix").read_text(encoding="utf-8")
    assert 'system.stateVersion = "25.11"' in systems


def test_boot_artifacts_apply_runtime_xname_identity() -> None:
    boot_artifacts = (PROJECT_ROOT / "nix" / "boot-artifacts.nix").read_text(encoding="utf-8")

    assert "openchami-xname-identity" in boot_artifacts
    assert "/proc/cmdline" in boot_artifacts
    assert "xname=" in boot_artifacts
    assert "/run/openchami/xname" in boot_artifacts
    assert 'serial-getty@ttyS0.service' in boot_artifacts
    assert 'bashrc.local' in boot_artifacts
    assert 'export PS1=' in boot_artifacts


def test_boot_artifacts_define_supported_test_node_images() -> None:
    boot_artifacts = (PROJECT_ROOT / "nix" / "boot-artifacts.nix").read_text(encoding="utf-8")

    assert 'bootImage ? "nixos"' in boot_artifacts
    assert "almalinux" in boot_artifacts
    assert "opensuse" in boot_artifacts
    assert "ubuntu" in boot_artifacts
    assert "nixos" in boot_artifacts
    assert "consoleReadyPattern" in boot_artifacts
    assert "unsupported test node image" in boot_artifacts
