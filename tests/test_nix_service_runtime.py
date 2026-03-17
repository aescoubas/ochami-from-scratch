"""Regression tests for local-image runtime parity."""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class TestServiceCommandPaths:
    """Service definitions should match the binaries exposed by local images."""

    def test_smd_init_uses_bin_path(self):
        content = (ROOT / "nix" / "services" / "smd.nix").read_text()
        assert 'command = "/bin/smd-init -migrationsdir /persistent_migrations/postgres";' in content

    def test_bss_init_uses_bin_path(self):
        content = (ROOT / "nix" / "services" / "bss.nix").read_text()
        assert 'command = "/bin/bss-init --postgres-migrations /migrations/postgres";' in content
        assert 'BSS_DBSTEP = "2";' in content

    def test_cloud_init_uses_bin_path(self):
        content = (ROOT / "nix" / "services" / "cloud-init.nix").read_text()
        assert 'command = "/bin/cloud-init-server' in content
        assert "--smd-url https://localhost:" in content
        assert "bash -c 'exec 3<>/dev/tcp/127.0.0.1/" in content

    def test_smd_healthcheck_uses_https(self):
        content = (ROOT / "nix" / "services" / "smd.nix").read_text()
        assert 'curl -kfs https://localhost:' in content

    def test_bss_uses_direct_smd_url(self):
        content = (ROOT / "nix" / "services" / "bss.nix").read_text()
        assert 'HSM_URL = "https://localhost:${smdPort}";' in content

    def test_kea_uses_host_cmds_hook_and_http_control_socket(self):
        content = (ROOT / "nix" / "services" / "kea.nix").read_text()
        assert 'libdhcp_host_cmds.so' in content
        assert 'control-sockets = [' in content
        assert 'socket-type = "http";' in content
        assert 'socket-address = "127.0.0.1";' in content
        assert "socket-port = defaults.ports.keaCtrlAgent;" in content
        assert 'name = "kea-ctrl-agent";' not in content
        assert 'kea-ctrl-agent.conf:/etc/kea/kea-ctrl-agent.conf:ro' not in content

    def test_kea_service_and_init_use_local_image_binary_paths(self):
        content = (ROOT / "nix" / "services" / "kea.nix").read_text()
        assert 'command = "/bin/kea-admin db-init pgsql -h localhost -P ${pgPort} -u kea-user -p $KEA_DB_PASSWORD -n kea";' in content
        assert 'command = "/bin/kea-dhcp4 -c /etc/kea/kea-dhcp4.conf";' in content

    def test_kea_service_uses_http_control_socket_healthcheck(self):
        content = (ROOT / "nix" / "services" / "kea.nix").read_text()
        assert "bash -ec ': >/dev/tcp/127.0.0.1/" in content

    def test_kea_sync_uses_http_proxy_for_smd_and_kea(self):
        content = (ROOT / "nix" / "services" / "kea.nix").read_text()
        assert 'name = "kea-sync";' in content
        assert 'command = "/bin/kea-sync";' in content
        assert 'KEA_SYNC_SMD_URL = "http://localhost:${httpPort}";' in content
        assert 'KEA_SYNC_KEA_URL = "http://localhost:${ctrlAgentPort}";' in content

    def test_kea_sync_waits_for_kea_http_control_socket(self):
        content = (ROOT / "nix" / "services" / "kea.nix").read_text()
        assert 'after = [ "smd" "kea-init" "kea" "http-server" ];' in content

    def test_http_server_has_healthcheck_for_compose_dependencies(self):
        content = (ROOT / "nix" / "services" / "nginx.nix").read_text()
        assert "healthCheck = \"bash -ec ': >/dev/tcp/127.0.0.1/" in content


class TestRuntimeImageAssets:
    """Local images should include the runtime assets they need at startup."""

    def test_pcs_image_packages_migrations_and_workdir(self):
        content = (ROOT / "nix" / "images" / "pcs.nix").read_text()
        assert "cp -r ${pcsSrc}/migrations app/migrations" in content
        assert 'WorkingDir = "/app";' in content

    def test_smd_image_packages_persistent_migrations(self):
        content = (ROOT / "nix" / "images" / "smd.nix").read_text()
        assert "mkdir -p persistent_migrations" in content
        assert "cp -r ${smdSrc}/migrations/. persistent_migrations/" in content

    def test_bss_image_packages_migrations(self):
        content = (ROOT / "nix" / "images" / "bss.nix").read_text()
        assert "mkdir -p migrations" in content
        assert "cp -r ${bssSrc}/migrations/. migrations/" in content

    def test_go_service_images_include_shell_for_compose_healthchecks(self):
        for name in ["smd.nix", "bss.nix", "pcs.nix", "cloud-init.nix", "kea.nix"]:
            content = (ROOT / "nix" / "images" / name).read_text()
            assert "pkgs.bash" in content

    def test_kea_image_packages_hook_libraries_and_binaries(self):
        content = (ROOT / "nix" / "images" / "kea.nix").read_text()
        assert "pkgs.kea" in content
        assert "lib/kea/hooks" in content
        assert 'name = "localhost/kea";' in content
        assert '"/bin/kea-dhcp4"' in content

    def test_http_server_image_defines_nobody_user(self):
        content = (ROOT / "nix" / "images" / "http-server.nix").read_text()
        assert "nobody:x:65534:65534:nobody" in content
        assert "nogroup:x:65534:" in content
        assert "mkdir -p tmp/nginx_client_body" in content
        assert "mkdir -p tmp/nginx_proxy" in content
        assert '"-c" "/etc/nginx/nginx.conf"' in content
        assert "etc/passwd" in content
        assert "etc/group" in content

    def test_tftp_image_defines_nobody_user_and_explicit_runtime_user(self):
        content = (ROOT / "nix" / "images" / "tftp.nix").read_text()
        assert "nobody:x:65534:65534:nobody" in content
        assert '"--user" "nobody"' in content
        assert "mkdir -p srv/tftp" in content

    def test_nginx_proxies_smd_over_https(self):
        content = (ROOT / "nix" / "services" / "nginx.nix").read_text()
        assert "proxy_pass https://localhost:${smdPort};" in content
        assert "proxy_ssl_verify off;" in content

    def test_nginx_rewrites_bss_api_prefix_before_proxying(self):
        content = (ROOT / "nix" / "services" / "nginx.nix").read_text()
        assert "rewrite ^/apis/bss/(.*)$ /$1 break;" in content
        assert "proxy_pass http://localhost:${bssPort};" in content

    def test_nginx_mounts_main_config_and_includes_conf_d(self):
        content = (ROOT / "nix" / "services" / "nginx.nix").read_text()
        assert "nginx.conf:/etc/nginx/nginx.conf:ro" in content
        assert '"nginx.conf" = nginxMainConf;' in content
        assert "include /etc/nginx/conf.d/*.conf;" in content

    def test_nginx_mounts_generated_boot_artifacts(self):
        content = (ROOT / "nix" / "services" / "nginx.nix").read_text()
        assert "/usr/share/nginx/html/artifacts:ro" in content
        assert "bootArtifacts.package" in content

    def test_nginx_boot_ipxe_uses_generated_kernel_args_without_rootfs(self):
        content = (ROOT / "nix" / "services" / "nginx.nix").read_text()
        assert "bootArtifacts.kernelFile" in content
        assert "bootArtifacts.initrdFile" in content
        assert "bootArtifacts.kernelArgs" in content
        assert "rootfs.squashfs" not in content

    def test_bss_boot_defaults_use_generated_kernel_args(self):
        content = (ROOT / "nix" / "services" / "bss.nix").read_text()
        assert "bootArtifacts.kernelArgs" in content
        assert "bootArtifacts.kernelFile" in content
        assert "bootArtifacts.initrdFile" in content
        assert "rootfs.squashfs" not in content
