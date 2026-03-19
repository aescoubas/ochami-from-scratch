"""Tests for scripts/ops/ bash scripts — verify they exist, are executable, and well-formed."""

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = ROOT / "scripts" / "ops"


class TestScriptsExist:
    """All required bash scripts must be present."""

    EXPECTED_SCRIPTS = [
        "lib/common.sh",
        "check-deps.sh",
        "create-test-vms.sh",
        "register-nodes.sh",
        "register-bss-defaults.sh",
        "health-check.sh",
        "lab-vm.sh",
        "teardown.sh",
        "lab-setup.sh",
        "deploy.sh",
        "build-images.sh",
    ]

    def test_all_scripts_exist(self):
        for script in self.EXPECTED_SCRIPTS:
            path = SCRIPTS_DIR / script
            assert path.is_file(), f"missing script: {script}"

    def test_all_scripts_are_executable(self):
        for script in self.EXPECTED_SCRIPTS:
            path = SCRIPTS_DIR / script
            assert os.access(path, os.X_OK), f"not executable: {script}"


class TestScriptStructure:
    """Verify scripts follow required conventions."""

    def _read_script(self, name: str) -> str:
        return (SCRIPTS_DIR / name).read_text()

    def test_common_sh_has_logging_functions(self):
        content = self._read_script("lib/common.sh")
        assert "log_info" in content
        assert "log_warn" in content
        assert "log_error" in content

    def test_common_sh_has_wait_for_url(self):
        content = self._read_script("lib/common.sh")
        assert "wait_for_url" in content

    def test_common_sh_bootstraps_macos_path(self):
        content = self._read_script("lib/common.sh")
        assert "bootstrap_host_path" in content
        assert "/opt/homebrew/bin" in content
        assert "/Applications/Docker.app/Contents/Resources/bin" in content
        assert "/nix/var/nix/profiles/default/bin" in content

    def test_common_sh_has_docker_compose_helpers(self):
        content = self._read_script("lib/common.sh")
        assert "docker_compose_available" in content
        assert "docker_compose_label" in content
        assert "docker_daemon_reachable" in content
        assert "docker_compose()" in content

    def test_common_sh_enables_nix_flakes(self):
        content = self._read_script("lib/common.sh")
        assert "ensure_nix_flake_support" in content
        assert "experimental-features = nix-command flakes" in content
        assert "nix_flake_ref" in content
        assert "nix_ssh_store_url" in content
        assert "default_lab_vm_libvirt_uri" in content
        assert "libvirt_uri_is_session" in content
        assert "qemu_system_bin_from_vm_runner" in content
        assert "qemu_img_bin_from_vm_runner" in content
        assert "mkfs_ext4_bin_from_vm_runner" in content

    def test_common_sh_has_secret_generation(self):
        content = self._read_script("lib/common.sh")
        assert "generate_secret" in content
        assert "ensure_secrets_file" in content
        assert 'LIBVIRT_BMC_USER=admin' in content
        assert 'LIBVIRT_BMC_PASSWORD=password' in content

    def test_common_sh_has_bridge_carrier_helpers(self):
        content = self._read_script("lib/common.sh")
        assert "ensure_libvirt_network" in content
        assert "pxe-net" in content
        assert "virbr-pxe" in content
        assert "ensure_bridge_carrier" in content
        assert "remove_bridge_carrier_dummy" in content
        assert "disable_conflicting_dhcp_networks" in content
        assert "restore_conflicting_dhcp_networks" in content

    def test_common_sh_has_dry_run_support(self):
        content = self._read_script("lib/common.sh")
        assert "DRY_RUN" in content
        assert "run_cmd" in content

    def test_scripts_source_common(self):
        """All operational scripts should source lib/common.sh."""
        for name in ["check-deps.sh", "create-test-vms.sh", "health-check.sh", "teardown.sh",
                      "deploy.sh", "register-nodes.sh", "register-bss-defaults.sh"]:
            content = self._read_script(name)
            assert "common.sh" in content, f"{name} should source common.sh"

    def test_scripts_use_set_euo_pipefail(self):
        """common.sh sets strict mode; scripts source it."""
        content = self._read_script("lib/common.sh")
        assert "set -euo pipefail" in content

    def test_check_deps_supports_all_methods(self):
        content = self._read_script("check-deps.sh")
        assert "compose" in content
        assert "lab-vm" in content
        assert "quadlets" in content
        assert "minikube" in content
        assert "check ss" in content
        assert "check ip" in content
        assert "check timeout" in content
        assert "docker_daemon_reachable" in content
        assert "OPENCHAMI_ALLOW_UNSUPPORTED_DARWIN" in content
        assert "OPENCHAMI_LAB_VM_BUILD_HOST" in content
        assert "BatchMode=yes" in content
        assert "passwordless sudo" in content
        assert 'check virsh "libvirt management"' in content
        assert 'check qemu-img "disk image creation"' in content
        assert 'check mkfs.ext4 "ext4 disk formatting"' in content
        assert "Nix-built lab VM closure on Darwin" in content
        assert "libvirt_uri_is_session" in content

    def test_teardown_supports_all_methods(self):
        content = self._read_script("teardown.sh")
        assert "compose" in content
        assert "lab-vm" in content
        assert "quadlets" in content
        assert "minikube" in content

    def test_deploy_runs_all_steps(self):
        content = self._read_script("deploy.sh")
        assert "check-deps.sh" in content
        assert "health-check.sh" in content
        assert "register-bss-defaults.sh" in content
        assert "build-images.sh" in content
        assert "lab-vm.sh" in content

    def test_deploy_builds_images_before_services(self):
        content = self._read_script("deploy.sh")
        build_pos = content.index("build-images.sh")
        compose_up_pos = content.index("docker_compose")
        assert build_pos < compose_up_pos, \
            "build-images.sh should run before docker compose up"

    def test_deploy_supports_skip_image_build(self):
        content = self._read_script("deploy.sh")
        assert "SKIP_IMAGE_BUILD" in content
        assert "PROFILE" in content

    def test_register_nodes_uses_direct_smd_writes(self):
        content = self._read_script("register-nodes.sh")
        assert 'SMD_BASE_URL="https://' in content
        assert 'curl -skf' in content or 'curl -ksf' in content
        assert "SMD_PORT" in content
        assert "REDFISH_BMC_USER" in content
        assert "REDFISH_BMC_PASSWORD" in content
        assert "bmc_xname" in content
        assert 'RediscoverOnUpdate' in content
        assert '\\"RediscoverOnUpdate\\": true' in content or '"RediscoverOnUpdate": true' in content
        assert "-X PATCH" in content

    def test_deploy_uses_managed_generated_compose_file(self):
        content = self._read_script("deploy.sh")
        assert "docker-compose.generated.yml" in content
        assert 'cp "$GENERATED" "$COMPOSE_FILE"' in content
        assert 'if [ ! -f "$COMPOSE_FILE" ]' not in content
        assert 'NIX_FLAKE_REF' in content
        assert '#deploy-profile' in content
        assert "envsubst" in content
        assert "--wait" in content
        assert "CHECK_KEA=true" in content
        assert ".tmp/openchami-secrets.env" in content
        assert "ensure_bridge_carrier" in content
        assert "disable_conflicting_dhcp_networks" in content

    def test_create_test_vms_bootstraps_libvirt_and_registration(self):
        content = self._read_script("create-test-vms.sh")
        assert 'METHOD="${METHOD:-compose}"' in content
        assert "lab-vm" in content
        assert "--count" in content
        assert "virt-install" in content
        assert "qemu-img" in content
        assert 'LAB_VM_LIBVIRT_URI="${LAB_VM_LIBVIRT_URI:-$(default_lab_vm_libvirt_uri)}"' in content
        assert 'if ! libvirt_uri_is_session "$LIBVIRT_URI"; then' in content
        assert "register-nodes.sh" in content
        assert "register-bss-defaults.sh" in content
        assert 'LIBVIRT_BMC_IMAGE="${LIBVIRT_BMC_IMAGE:-localhost/libvirt-bmc:latest}"' in content
        assert 'EXPLICIT_LIBVIRT_BMC_USER="${LIBVIRT_BMC_USER:-}"' in content
        assert 'EXPLICIT_LIBVIRT_BMC_PASSWORD="${LIBVIRT_BMC_PASSWORD:-}"' in content
        assert '. "$SECRETS_FILE"' in content
        assert 'LIBVIRT_BMC_USER="${EXPLICIT_LIBVIRT_BMC_USER:-${LIBVIRT_BMC_USER:-admin}}"' in content
        assert 'LIBVIRT_BMC_PASSWORD="${EXPLICIT_LIBVIRT_BMC_PASSWORD:-${LIBVIRT_BMC_PASSWORD:-password}}"' in content
        assert "ochami-pxe-net" in content
        assert "virbr-ochami" in content
        assert "openchami-lab-net" in content
        assert "virbr-ochlab" in content
        assert "ensure_bridge_carrier" in content
        assert "docker_compose" in content
        assert "init_xname_layout" in content
        assert "bmc_xname_for_index" in content
        assert "xname_for_index" in content
        assert "bmc_ip_for_index" in content
        assert "domain_uuid" in content
        assert "ensure_compose_libvirt_bmc" in content
        assert "wait_for_compose_libvirt_bmc" in content
        assert "wait_for_component_endpoint" in content
        assert "wait_for_pcs_power_status" in content
        assert 'https://${bmc_ip}/redfish/v1/' in content
        assert "--no-deps" in content
        assert "kea kea-sync" in content
        assert "kea-ctrl-agent" not in content
        assert "kea-sync" in content
        assert "health-check.sh" in content
        assert "lab-vm.sh" in content
        assert "/v1/sync" in content
        assert "/boot/v1/bootscript" in content
        assert "/apis/bss/boot/v1/bootscript" in content
        assert 'arch=x86_64' in content
        assert "kernel --name kernel" in content
        assert "initrd --name initrd" in content
        assert 'LAB_VM_SHARED_NET_MCAST="${LAB_VM_SHARED_NET_MCAST:-' in content
        assert 'LAB_VM_COMPUTE_BOOT_CACHE_DIR="${LAB_VM_COMPUTE_BOOT_CACHE_DIR:-' in content
        assert 'LAB_VM_DIRECT_GUEST_HOST="${LAB_VM_DIRECT_GUEST_HOST:-10.0.2.2}"' in content
        assert "fetch_direct_qemu_second_stage_bootscript" in content
        assert "rewrite_direct_qemu_bootscript" in content
        assert "render_darwin_lab_vm_domain_xml" in content
        assert "start_darwin_libvirt_domain" in content
        assert "wait_for_darwin_libvirt_console" in content
        assert "darwin_libvirt_console_probe" in content
        assert 'script -q /dev/null "$virsh_bin" --connect "$LIBVIRT_URI" console "$domain_name" >"$probe_log" 2>&1' in content
        assert "run_darwin_libvirt_lab_vms" in content
        assert "<kernel>$(printf '%s' \"$DIRECT_QEMU_KERNEL_PATH\" | xml_escape)</kernel>" in content
        assert "<initrd>$(printf '%s' \"$DIRECT_QEMU_INITRD_PATH\" | xml_escape)</initrd>" in content
        assert "<cmdline>$(printf '%s' \"$DIRECT_QEMU_KERNEL_ARGS\" | xml_escape)</cmdline>" in content
        assert "<emulator>$(printf '%s' \"$DIRECT_QEMU_BIN\" | xml_escape)</emulator>" in content
        assert "<interface type='user'>" in content
        assert "libvirt session console output confirms" in content
        assert 'ds=nocloud-net;s=http://${LAB_VM_DIRECT_GUEST_HOST}:${LAB_VM_CONTROLLER_HTTP_PORT}/cloud-init/' in content
        assert "ochami-netboot" in content
        assert "METHOD=lab-vm compute VMs currently require a Linux host" not in content
        assert "xname,mac,ip,bmc_ip,bmc_xname,domain" in content
        assert "xname,mac,ip,bmc_ip,bmc_xname" in content

    def test_lab_setup_uses_ochami_libvirt_names(self):
        content = self._read_script("lab-setup.sh")
        assert 'NETWORK_NAME="${NETWORK_NAME:-ochami-pxe-net}"' in content
        assert 'NETWORK_BRIDGE="${NETWORK_BRIDGE:-virbr-ochami}"' in content

    def test_teardown_uses_managed_generated_compose_file(self):
        content = self._read_script("teardown.sh")
        assert '$(dirname "$(dirname "$SCRIPT_DIR")")/ochami-docker-compose' in content
        assert "docker-compose.generated.yml" in content
        assert '.tmp/openchami-secrets.env' in content
        assert 'SECRETS_FILE="${OPENCHAMI_SECRETS:-' in content
        assert 'ensure_secrets_file "$SECRETS_FILE"' in content
        assert '--env-file "$SECRETS_FILE"' in content
        assert 'LIBVIRT_BMC_CONTAINER_PREFIX="${LIBVIRT_BMC_CONTAINER_PREFIX:-ochami-libvirt-bmc}"' in content
        assert 'docker ps -a --filter "name=${LIBVIRT_BMC_CONTAINER_PREFIX}-"' in content
        assert "remove_bridge_carrier_dummy" in content
        assert "restore_conflicting_dhcp_networks" in content

    def test_build_images_sources_common(self):
        content = self._read_script("build-images.sh")
        assert "common.sh" in content

    def test_build_images_builds_all_oci_images(self):
        content = self._read_script("build-images.sh")
        assert "oci-images" in content
        assert "PROFILE" in content
        assert "SMD_SRC" in content
        assert "BSS_SRC" in content
        assert "PCS_SRC" in content
        assert "CLOUD_INIT_SRC" in content
        assert "KEA_SYNC_SRC" in content
        assert "--impure" in content
        assert "https://github.com/aescoubas/kea-sync.git" in content
        assert "git clone --depth 1" in content

    def test_build_images_supports_runtime_flag(self):
        content = self._read_script("build-images.sh")
        assert "--runtime" in content
        assert "SMD_IMAGE_TAG" in content
        assert "BSS_IMAGE_TAG" in content
        assert "PCS_IMAGE_TAG" in content
        assert "CLOUD_INIT_IMAGE_TAG" in content
        assert "EXPLICIT_KEA_SYNC_SRC" in content
        assert "KEA_SYNC_SRC" in content

    def test_lab_vm_script_manages_controller_vm(self):
        content = self._read_script("lab-vm.sh")
        assert "lab-controller-vm" in content
        assert "lab-controller-system" in content
        assert 'LAB_VM_LIBVIRT_URI="${LAB_VM_LIBVIRT_URI:-$(default_lab_vm_libvirt_uri)}"' in content
        assert 'LAB_VM_CONTROLLER_DOMAIN="${LAB_VM_CONTROLLER_DOMAIN:-openchami-controller}"' in content
        assert 'LAB_VM_CONTROLLER_BSS_PORT=' in content
        assert 'LAB_VM_CONTROLLER_KEA_CTRL_PORT=' in content
        assert 'LAB_VM_CONTROLLER_SMD_PORT=' in content
        assert 'DEFAULT_LAB_VM_CONTROLLER_DISK_SIZE=' in content
        assert 'DEFAULT_LAB_VM_HEALTH_ATTEMPTS=' in content
        assert 'LAB_VM_CONTROLLER_DIRECT_DISK_LAYOUT_VERSION=' in content
        assert 'controller.direct-disk-layout' in content
        assert 'openchami-controller.qcow2' in content
        assert 'LAB_VM_NETWORK_NAME="${LAB_VM_NETWORK_NAME:-openchami-lab-net}"' in content
        assert 'LAB_VM_NETWORK_BRIDGE="${LAB_VM_NETWORK_BRIDGE:-virbr-ochlab}"' in content
        assert 'LAB_VM_SHARED_NET_MCAST="${LAB_VM_SHARED_NET_MCAST:-' in content
        assert 'LAB_VM_CONTROLLER_PXE_MAC="${LAB_VM_CONTROLLER_PXE_MAC:-' in content
        assert "lab_vm_uses_managed_network" in content
        assert "backend type='passt'" in content
        assert "portForward proto='tcp'" in content
        assert "<interface type='network'>" in content
        assert "<source network='" in content
        assert "<interface type='user'>" in content
        assert "<emulator>$(printf '%s' \"$LAB_VM_HOST_QEMU_BIN\" | xml_escape)</emulator>" in content
        assert "net-start" in content
        assert 'virsh --connect "$LAB_VM_LIBVIRT_URI"' in content
        assert "serial type='pty'" in content
        assert '"$qemu_img_bin" create -f raw' in content
        assert '"$mkfs_ext4_bin" -L nixos' in content
        assert "hostfwd=tcp:127.0.0.1:" in content
        assert '${LAB_VM_CONTROLLER_BSS_PORT}-:27778' in content
        assert '${LAB_VM_CONTROLLER_KEA_CTRL_PORT}-:8000' in content
        assert '${LAB_VM_CONTROLLER_SMD_PORT}-:27779' in content
        assert "boot.ipxe" in content
        assert "/boot/v1/bootparameters" in content
        assert "/hsm/v2/service/ready" in content
        assert "/dev/tcp/127.0.0.1/" in content
        assert "controller.pid" in content
        assert "controller.qemu.pid" in content
        assert "ssh://lab@127.0.0.1:" in content
        assert "OPENCHAMI_LAB_VM_BUILD_HOST" in content
        assert "OPENCHAMI_LAB_VM_BUILD_REPO_PATH" in content
        assert "nix copy --no-check-sigs --stdin --from" in content
        assert "--no-check-sigs" in content
        assert 'sudo -n env PATH="$PATH"' in content
        assert 'sed "s#~/#$HOME/#g"' in content
        assert "resolve_controller_vm_host_qemu_tools" in content
        assert "qemu_system_bin_from_vm_runner" in content
        assert "qemu_img_bin_from_vm_runner" in content
        assert "mkfs_ext4_bin_from_vm_runner" in content
        assert "mcast=" in content
        assert "stop_direct_compute_vms" in content
        assert "reconcile_direct_controller_vm_disk_layout" in content
        assert "start)" in content
        assert "stop)" in content
        assert "health)" in content

    def test_lab_vm_raises_darwin_controller_defaults(self):
        content = self._read_script("lab-vm.sh")
        assert 'DEFAULT_LAB_VM_CONTROLLER_MEMORY_MIB="2048"' in content
        assert 'DEFAULT_LAB_VM_CONTROLLER_VCPUS="1"' in content
        assert 'DEFAULT_LAB_VM_CONTROLLER_MEMORY_MIB="4096"' in content
        assert 'DEFAULT_LAB_VM_CONTROLLER_VCPUS="4"' in content
        assert 'LAB_VM_CONTROLLER_MEMORY_MIB="${LAB_VM_CONTROLLER_MEMORY_MIB:-${DEFAULT_LAB_VM_CONTROLLER_MEMORY_MIB}}"' in content
        assert 'LAB_VM_CONTROLLER_VCPUS="${LAB_VM_CONTROLLER_VCPUS:-${DEFAULT_LAB_VM_CONTROLLER_VCPUS}}"' in content

    def test_scripts_support_dry_run(self):
        for name in ["check-deps.sh", "health-check.sh", "lab-vm.sh", "teardown.sh",
                      "deploy.sh", "register-bss-defaults.sh"]:
            content = self._read_script(name)
            assert "dry-run" in content or "DRY_RUN" in content, \
                f"{name} should support --dry-run"

    def test_lab_vm_check_deps_relies_on_nix_built_qemu_on_darwin(self):
        content = self._read_script("check-deps.sh")
        assert 'check qemu-system-x86_64 "Darwin direct-QEMU compute VMs"' not in content

    def test_health_check_can_fail_when_kea_is_down(self):
        content = self._read_script("health-check.sh")
        assert 'KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"' in content
        assert "CHECK_KEA" in content
        assert "checking kea container health via docker compose" in content
        assert "ps --format json kea" in content
        assert "checking kea on UDP port" in content
        assert "ss -lun" in content
        assert "/readiness" in content
        assert "artifacts/opensuse/vmlinuz-lts" in content

    def test_register_bss_defaults_uses_generated_boot_artifacts(self):
        content = self._read_script("register-bss-defaults.sh")
        assert "NIX_FLAKE_REF" in content
        assert "#boot-artifacts" in content
        assert "kernel-params" in content
        assert "vmlinuz-lts" in content
        assert "initramfs-lts" in content
        assert "rootfs.squashfs" not in content

    def test_create_test_vms_uses_default_kea_sync_port(self):
        content = self._read_script("create-test-vms.sh")
        assert 'KEA_SYNC_PORT="${KEA_SYNC_PORT:-28080}"' in content


class TestMakefileTargets:
    """Verify Makefile has the new operational targets."""

    def setup_method(self):
        self.content = (ROOT / "Makefile").read_text()

    def test_has_deploy_target(self):
        assert "deploy:" in self.content

    def test_has_teardown_target(self):
        assert "teardown:" in self.content

    def test_has_check_target(self):
        assert "check:" in self.content

    def test_has_generate_target(self):
        assert "generate:" in self.content

    def test_deploy_uses_method_variable(self):
        assert "$(METHOD)" in self.content

    def test_deploy_calls_script(self):
        assert "scripts/ops/deploy.sh" in self.content

    def test_has_build_images_target(self):
        assert "build-images:" in self.content
        assert "build-images.sh" in self.content
        assert "SMD_SRC" in self.content
        assert "BSS_SRC" in self.content
        assert "PCS_SRC" in self.content
        assert "CLOUD_INIT_SRC" in self.content
        assert "KEA_SYNC_SRC" in self.content

    def test_has_create_test_vms_target(self):
        assert "create-test-vms:" in self.content
        assert "create-test-vms.sh" in self.content
        assert "--method $(METHOD)" in self.content

    def test_has_generate_images_target(self):
        assert "generate-images:" in self.content
        assert "$(NIX) build $(NIX_FLAKE_REF)#boot-artifacts" in self.content

    def test_has_lab_vm_build_targets(self):
        assert "build-lab-controller-vm:" in self.content
        assert "$(NIX) build $(NIX_FLAKE_REF)#lab-controller-vm" in self.content
        assert "build-lab-boot-node-vm:" in self.content
        assert "$(NIX) build $(NIX_FLAKE_REF)#lab-boot-node-vm" in self.content

    def test_makefile_exposes_local_source_override_variables(self):
        for name in ["SMD_SRC", "BSS_SRC", "PCS_SRC", "CLOUD_INIT_SRC", "KEA_SYNC_SRC"]:
            assert f"{name} ?=" in self.content

    def test_makefile_forwards_local_source_override_variables(self):
        for name in ["SMD_SRC", "BSS_SRC", "PCS_SRC", "CLOUD_INIT_SRC", "KEA_SYNC_SRC"]:
            assert f'{name}="$({name})"' in self.content
