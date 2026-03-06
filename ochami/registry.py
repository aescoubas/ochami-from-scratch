from __future__ import annotations

import csv
from dataclasses import dataclass
import json
from pathlib import Path
import tempfile
import time
from urllib import error, request

from ochami.config import DeployConfig, DiscoveryMethod
from ochami.defaults import BSS_PORT, HTTP_PORT, SMD_PORT
from ochami.utils import command_exists, is_macos, run, run_output, validate_ip, validate_mac


@dataclass(slots=True)
class ServiceEndpoints:
    smd_ip: str
    bss_ip: str


class RegistryManager:
    def __init__(self, project_root: Path, runner=run, output_runner=run_output, macos: bool | None = None) -> None:
        self.project_root = project_root
        self._runner = runner
        self._output_runner = output_runner
        self._is_macos = is_macos() if macos is None else macos

    def wait_for_services(self, checks: list[tuple[str, str]], dry_run: bool) -> None:
        if dry_run:
            return
        for name, url in checks:
            self._wait_for_url(url, name)

    def register_bss_defaults(self, host: str, host_ip: str, extra_params: str, dry_run: bool) -> None:
        if dry_run:
            return
        artifacts_url = f"http://{host_ip}:{HTTP_PORT}/artifacts/opensuse"
        params = f"console=ttyS0 ip=dhcp rd.neednet=1 root=live:{artifacts_url}/rootfs.squashfs"
        if extra_params:
            params = f"{params} {extra_params}"
        body = {
            "hosts": ["Default"],
            "kernel": f"{artifacts_url}/vmlinuz-lts",
            "initrd": f"{artifacts_url}/initramfs-lts",
            "params": params,
        }

        url = f"http://{host}:{BSS_PORT}/boot/v1/bootparameters"
        last_status = 0
        for _ in range(30):
            status, _ = self._request_json("PUT", url, body)
            last_status = status
            if 200 <= status < 300:
                return
            time.sleep(2)

        raise RuntimeError(f"failed to register default boot params (status={last_status})")

    def run_post_deploy_flow(self, config: DeployConfig, host_ip: str, orchestrator: str, dry_run: bool) -> None:
        if dry_run:
            return

        if config.discovery_method == DiscoveryMethod.MAGELLAN:
            self._run_magellan(config, host_ip, orchestrator, dry_run)
        elif config.nodes_file is not None:
            self._register_nodes_file(config, host_ip, orchestrator, dry_run)

        if config.num_vms <= 0 or self._is_macos:
            return

        if config.discovery_method == DiscoveryMethod.MAGELLAN:
            for idx in range(config.num_vms):
                self._create_vm(f"virtual-compute-node-{idx}", dry_run=dry_run)
            self._run_magellan(config, host_ip, orchestrator, dry_run)
            return

        current_ip_octet = 50
        for idx in range(config.num_vms):
            vm_name = f"virtual-compute-node-{idx}"
            component_id = f"x0c0s{idx}b0n0"
            static_ip = f"192.168.100.{current_ip_octet}"
            self._create_vm(vm_name, dry_run=dry_run)
            self._register_local_vm(
                vm_name=vm_name,
                ip_address=static_ip,
                component_id=component_id,
                nid=idx + 1,
                host_ip=host_ip,
                orchestrator=orchestrator,
                dry_run=dry_run,
            )
            self._runner(["sudo", "virsh", "destroy", vm_name], dry_run=dry_run, check=False)
            self._runner(["sudo", "virsh", "start", vm_name], dry_run=dry_run, check=False)
            current_ip_octet += 1

    def register_hardware_node(
        self,
        *,
        mac: str,
        ip: str,
        component_id: str,
        nid: int,
        bmc_ip: str,
        bmc_user: str,
        bmc_pass: str,
        host_ip: str,
        orchestrator: str,
        dry_run: bool = False,
    ) -> None:
        validate_mac(mac, "mac")
        validate_ip(ip, "ip")
        validate_ip(bmc_ip, "bmc_ip")
        if nid < 0:
            raise ValueError("nid must be non-negative")
        endpoints = self._resolve_service_endpoints(host_ip, orchestrator, dry_run=dry_run)
        self._register_node_with_endpoints(
            mac=mac,
            ip=ip,
            component_id=component_id,
            nid=nid,
            bmc_ip=bmc_ip,
            bmc_user=bmc_user,
            bmc_pass=bmc_pass,
            endpoints=endpoints,
            host_ip=host_ip,
            orchestrator=orchestrator,
            dry_run=dry_run,
        )

    def _register_nodes_file(self, config: DeployConfig, host_ip: str, orchestrator: str, dry_run: bool) -> None:
        if config.nodes_file is None:
            return
        endpoints = self._resolve_service_endpoints(host_ip, orchestrator, dry_run=dry_run)

        with config.nodes_file.open("r", encoding="utf-8") as handle:
            reader = csv.reader(handle)
            for row in reader:
                if not row:
                    continue
                if row[0].strip().startswith("#"):
                    continue
                if len(row) < 7:
                    raise RuntimeError("nodes file rows must have 7 columns")
                mac, ip, component_id, nid, bmc_ip, bmc_user, bmc_pass = [item.strip() for item in row[:7]]
                validate_mac(mac, "nodes_file.mac")
                validate_ip(ip, "nodes_file.ip")
                validate_ip(bmc_ip, "nodes_file.bmc_ip")
                if not nid.isdigit():
                    raise RuntimeError(f"nodes_file.nid must be a non-negative integer: {nid!r}")
                self._register_node_with_endpoints(
                    mac=mac,
                    ip=ip,
                    component_id=component_id,
                    nid=int(nid),
                    bmc_ip=bmc_ip,
                    bmc_user=bmc_user,
                    bmc_pass=bmc_pass,
                    endpoints=endpoints,
                    host_ip=host_ip,
                    orchestrator=orchestrator,
                    dry_run=dry_run,
                )

    def _run_magellan(self, config: DeployConfig, host_ip: str, orchestrator: str, dry_run: bool) -> None:
        del orchestrator
        if not command_exists("magellan") and not dry_run:
            raise RuntimeError("magellan is required for discovery_method=magellan")

        smd_ip = self._resolve_smd_service_ip(host_ip, dry_run=dry_run)
        if not smd_ip:
            raise RuntimeError("could not resolve SMD service IP for Magellan discovery")

        cache = config.magellan_cache or f"/tmp/{Path.home().name}/magellan/assets.db"
        cache_path = Path(cache)
        if not dry_run:
            cache_path.parent.mkdir(parents=True, exist_ok=True)

        scan_cmd = ["magellan", "scan", "--cache", cache]
        has_scan_target = False

        if config.magellan_subnets:
            for subnet in [item.strip() for item in config.magellan_subnets.split(",") if item.strip()]:
                scan_cmd.extend(["--subnet", subnet])
                has_scan_target = True

        scan_hosts = [item.strip() for item in config.magellan_hosts.split(",") if item.strip()]
        if scan_hosts:
            has_scan_target = True

        if not has_scan_target:
            raise RuntimeError("magellan discovery requires magellan_subnets and/or magellan_hosts")

        if config.magellan_subnet_mask:
            scan_cmd.extend(["--subnet-mask", config.magellan_subnet_mask])
        if config.magellan_insecure:
            scan_cmd.append("--insecure")
        scan_cmd.extend(scan_hosts)

        collect_cmd = ["magellan", "collect", "--cache", cache, "--show", "--format", "json"]
        if config.magellan_bmc_user:
            collect_cmd.extend(["--username", config.magellan_bmc_user])
        if config.magellan_bmc_pass:
            collect_cmd.extend(["--password", config.magellan_bmc_pass])
        if config.magellan_bmc_id_map:
            collect_cmd.extend(["--bmc-id-map", config.magellan_bmc_id_map])
        if config.magellan_insecure:
            collect_cmd.append("--insecure")

        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
            collect_path = Path(tmp.name)

        self._runner(scan_cmd, dry_run=dry_run)
        output = self._output_runner(collect_cmd, dry_run=dry_run, check=False)
        if not dry_run:
            collect_path.write_text(output, encoding="utf-8")
            compact = "".join(output.split())
            if not compact or compact == "[]":
                collect_path.unlink(missing_ok=True)
                return

        self._runner(["magellan", "send", "-d", f"@{collect_path}", f"http://{smd_ip}:{SMD_PORT}"], dry_run=dry_run)
        if not dry_run:
            collect_path.unlink(missing_ok=True)

    def _resolve_service_endpoints(self, host_ip: str, orchestrator: str, dry_run: bool) -> ServiceEndpoints:
        if orchestrator in {"quadlets", "docker-compose"}:
            return ServiceEndpoints(smd_ip=host_ip, bss_ip=host_ip)

        smd_ip = self._output_runner(
            ["minikube", "kubectl", "--", "get", "svc", "ochami-smd", "-n", "ochami", "-o", "jsonpath={.spec.clusterIP}"],
            check=False,
            dry_run=dry_run,
        ).strip()
        bss_ip = self._output_runner(
            ["minikube", "kubectl", "--", "get", "svc", "ochami-bss", "-n", "ochami", "-o", "jsonpath={.spec.clusterIP}"],
            check=False,
            dry_run=dry_run,
        ).strip()
        if not smd_ip or not bss_ip:
            raise RuntimeError("could not resolve SMD or BSS service IP")
        return ServiceEndpoints(smd_ip=smd_ip, bss_ip=bss_ip)

    def _resolve_smd_service_ip(self, host_ip: str, dry_run: bool) -> str:
        output = self._output_runner(
            ["minikube", "kubectl", "--", "get", "svc", "ochami-smd", "-n", "ochami", "-o", "jsonpath={.spec.clusterIP}"],
            check=False,
            dry_run=dry_run,
        ).strip()
        return output or host_ip

    def _create_vm(self, vm_name: str, dry_run: bool) -> None:
        if self._is_macos:
            raise RuntimeError("local VM creation is not supported on macOS")

        if self._runner(["virsh", "dominfo", vm_name], check=False, dry_run=dry_run) == 0:
            return

        if self._runner(["virsh", "net-info", "pxe-net"], check=False, dry_run=dry_run) != 0:
            network_xml = (
                "<network>"
                "<name>pxe-net</name>"
                "<uuid>c8f874f7-dd7a-465c-862a-ec30f41ac4bb</uuid>"
                "<bridge name='virbr-pxe' stp='on' delay='0'/>"
                "<mac address='52:54:00:d8:3f:37'/>"
                "<ip address='192.168.100.1' netmask='255.255.255.0'></ip>"
                "</network>"
            )
            self._runner(["bash", "-lc", f"cat <<'EOF' | virsh net-define /dev/stdin\n{network_xml}\nEOF"], dry_run=dry_run)
            self._runner(["virsh", "net-start", "pxe-net"], dry_run=dry_run, check=False)
            self._runner(["virsh", "net-autostart", "pxe-net"], dry_run=dry_run, check=False)

        self._runner(
            [
                "sudo",
                "virt-install",
                "--name",
                vm_name,
                "--memory",
                "2048",
                "--vcpus",
                "1",
                "--disk",
                "none",
                "--network",
                "network=pxe-net,model=virtio",
                "--os-variant",
                "centos-stream9",
                "--graphics",
                "none",
                "--console",
                "pty,target_type=serial",
                "--pxe",
                "--virt-type",
                "kvm",
                "--noautoconsole",
                "--boot",
                "network,hd",
            ],
            dry_run=dry_run,
        )

    def _register_local_vm(
        self,
        *,
        vm_name: str,
        ip_address: str,
        component_id: str,
        nid: int,
        host_ip: str,
        orchestrator: str,
        dry_run: bool,
    ) -> None:
        endpoints = self._resolve_service_endpoints(host_ip, orchestrator, dry_run=dry_run)
        mac = self._vm_mac(vm_name, dry_run=dry_run)
        emulator_ip = self._emulator_ip(vm_name, host_ip=host_ip, orchestrator=orchestrator, dry_run=dry_run)
        self._register_node_with_endpoints(
            mac=mac,
            ip=ip_address,
            component_id=component_id,
            nid=nid,
            bmc_ip=emulator_ip,
            bmc_user="root",
            bmc_pass="password",
            endpoints=endpoints,
            host_ip=host_ip,
            orchestrator=orchestrator,
            dry_run=dry_run,
        )

    def _vm_mac(self, vm_name: str, dry_run: bool) -> str:
        output = self._output_runner(["sudo", "virsh", "domiflist", vm_name], check=False, dry_run=dry_run)
        for line in output.splitlines():
            columns = line.split()
            if len(columns) >= 5 and columns[2] == "pxe-net":
                mac = columns[4]
                validate_mac(mac, "vm.mac")
                return mac
        raise RuntimeError(f"could not determine MAC address for VM {vm_name}")

    def _emulator_ip(self, vm_name: str, *, host_ip: str, orchestrator: str, dry_run: bool) -> str:
        if orchestrator in {"quadlets", "docker-compose"}:
            return host_ip

        suffix = vm_name.rsplit("-", 1)[-1]
        if not suffix.isdigit():
            return host_ip
        pod_name = f"ochami-redfish-emulator-{suffix}"
        pod_ip = self._output_runner(
            ["minikube", "kubectl", "--", "get", "pod", "-n", "ochami", pod_name, "-o", "jsonpath={.status.podIP}"],
            check=False,
            dry_run=dry_run,
        ).strip()
        return pod_ip or host_ip

    def _register_node_with_endpoints(
        self,
        *,
        mac: str,
        ip: str,
        component_id: str,
        nid: int,
        bmc_ip: str,
        bmc_user: str,
        bmc_pass: str,
        endpoints: ServiceEndpoints,
        host_ip: str,
        orchestrator: str,
        dry_run: bool,
    ) -> None:
        if dry_run:
            return

        artifacts_url = f"http://{host_ip}:{HTTP_PORT}/artifacts/opensuse"
        bmc_xname = component_id.rsplit("n", 1)[0] if "n" in component_id else component_id

        self._request_json(
            "POST",
            f"http://{endpoints.smd_ip}:{SMD_PORT}/hsm/v2/State/Components",
            {
                "Components": [
                    {
                        "ID": component_id,
                        "Type": "Node",
                        "State": "On",
                        "Flag": "OK",
                        "Role": "Compute",
                        "NID": nid,
                        "NetType": "Sling",
                    }
                ]
            },
        )
        self._request_json(
            "POST",
            f"http://{endpoints.smd_ip}:{SMD_PORT}/hsm/v2/Inventory/EthernetInterfaces",
            {
                "Description": "Node NIC",
                "MACAddress": mac,
                "IPAddresses": [{"IPAddress": ip}],
                "ComponentID": component_id,
            },
        )

        redfish_payload = {
            "ID": bmc_xname,
            "RediscoverOnUpdate": True,
            "Hostname": bmc_ip,
            "User": bmc_user,
            "Password": bmc_pass,
        }
        status, _ = self._request_json(
            "POST",
            f"http://{endpoints.smd_ip}:{SMD_PORT}/hsm/v2/Inventory/RedfishEndpoints",
            redfish_payload,
        )
        if status == 409:
            self._request_json(
                "PUT",
                f"http://{endpoints.smd_ip}:{SMD_PORT}/hsm/v2/Inventory/RedfishEndpoints/{bmc_xname}",
                redfish_payload,
            )

        self._request_json(
            "POST",
            f"http://{endpoints.smd_ip}:{SMD_PORT}/hsm/v2/Inventory/Discover",
            {"xnames": [bmc_xname]},
        )

        self._request_json(
            "PUT",
            f"http://{endpoints.bss_ip}:{BSS_PORT}/boot/v1/bootparameters",
            {
                "hosts": [component_id],
                "macs": [mac],
                "kernel": f"{artifacts_url}/vmlinuz-lts",
                "initrd": f"{artifacts_url}/initramfs-lts",
                "params": f"console=ttyS0 ip=dhcp rd.neednet=1 root=live:{artifacts_url}/rootfs.squashfs",
            },
        )

        self._apply_bss_nodes_workaround(
            mac=mac,
            nid=nid,
            component_id=component_id,
            orchestrator=orchestrator,
            dry_run=dry_run,
        )

    def _apply_bss_nodes_workaround(self, *, mac: str, nid: int, component_id: str, orchestrator: str, dry_run: bool) -> None:
        update_sql = f"UPDATE nodes SET boot_mac = '{mac}', nid = {nid} WHERE xname = '{component_id}';"
        if orchestrator == "docker-compose":
            container_name = self._first_matching_container(["docker", "ps", "--format", "{{.Names}}"], "postgres", dry_run=dry_run)
            if container_name:
                self._runner(["docker", "exec", container_name, "bash", "-lc", f"psql -U bss-user -d bssdb -c \"{update_sql}\""], dry_run=dry_run, check=False)
            return

        if orchestrator == "quadlets":
            container_name = self._first_matching_container(
                ["sudo", "podman", "ps", "--format", "{{.Names}}"],
                "postgres",
                dry_run=dry_run,
            )
            if container_name:
                self._runner(["sudo", "podman", "exec", container_name, "bash", "-lc", f"psql -U bss-user -d bssdb -c \"{update_sql}\""], dry_run=dry_run, check=False)
            return

        self._runner(
            ["minikube", "kubectl", "--", "exec", "-n", "ochami", "ochami-postgres", "--", "bash", "-lc", f"psql -U bss-user -d bssdb -c \"{update_sql}\""],
            dry_run=dry_run,
            check=False,
        )

    def _first_matching_container(self, command: list[str], token: str, dry_run: bool) -> str:
        output = self._output_runner(command, check=False, dry_run=dry_run)
        for name in output.splitlines():
            if token in name:
                return name.strip()
        return ""

    def _request_json(self, method: str, url: str, payload: dict[str, object]) -> tuple[int, str]:
        encoded = json.dumps(payload).encode("utf-8")
        req = request.Request(url=url, data=encoded, method=method, headers={"Content-Type": "application/json"})
        try:
            with request.urlopen(req, timeout=10) as response:  # nosec: B310
                return response.status, response.read().decode("utf-8", errors="replace")
        except error.HTTPError as exc:
            return exc.code, exc.read().decode("utf-8", errors="replace")
        except error.URLError:
            return 0, ""

    def _wait_for_url(self, url: str, label: str, max_attempts: int = 60, interval_seconds: int = 2) -> None:
        last_error: Exception | None = None
        for _ in range(max_attempts):
            try:
                with request.urlopen(url, timeout=5):  # nosec: B310
                    return
            except (error.URLError, TimeoutError) as exc:
                last_error = exc
                time.sleep(interval_seconds)
        raise RuntimeError(f"{label} did not become ready: {last_error}")
