# Kea DHCP4 - db-init oneshot + DHCP service + kea-sync.
# Config file has $KEA_DB_PASSWORD placeholder for envsubst at activation.
{ defaults, hostIP, pxeInterface, dhcpRange, pxeCidr }:

let
  pgPort = toString defaults.ports.postgres;
  httpPort = toString defaults.ports.http;
  ctrlAgentPort = toString defaults.ports.keaCtrlAgent;
  syncPort = toString defaults.ports.keaSync;

  keaConfig = builtins.toJSON {
    Dhcp4 = {
      interfaces-config.interfaces = [ pxeInterface ];
      control-sockets = [
        {
          socket-type = "http";
          socket-address = "127.0.0.1";
          socket-port = defaults.ports.keaCtrlAgent;
        }
      ];
      hooks-libraries = [
        { library = "${defaults.containerPaths.keaHooksDir}/libdhcp_pgsql.so"; }
        { library = "${defaults.containerPaths.keaHooksDir}/libdhcp_host_cmds.so"; }
      ];
      lease-database = {
        type = "postgresql";
        name = "kea";
        user = "kea-user";
        password = "$KEA_DB_PASSWORD";
        host = "localhost";
        port = defaults.ports.postgres;
      };
      hosts-database = {
        type = "postgresql";
        name = "kea";
        user = "kea-user";
        password = "$KEA_DB_PASSWORD";
        host = "localhost";
        port = defaults.ports.postgres;
      };
      valid-lifetime = 300;
      renew-timer = 150;
      rebind-timer = 225;
      client-classes = [
        {
          name = "iPXE";
          test = "substring(option[77].hex,0,4) == 'iPXE'";
          boot-file-name = "http://${hostIP}:${httpPort}/boot/v1/bootscript?mac=\${mac}";
        }
        {
          name = "BIOS";
          test = "option[93].hex == 0x0000";
          boot-file-name = "undionly.kpxe";
        }
        {
          name = "UEFI-64";
          test = "option[93].hex == 0x0007 or option[93].hex == 0x0009";
          boot-file-name = "ipxe.efi";
        }
      ];
      subnet4 = [
        {
          id = 1;
          subnet = "${hostIP}/${pxeCidr}";
          pools = [ { pool = dhcpRange; } ];
          option-data = [
            { name = "routers"; data = hostIP; }
            { name = "domain-name-servers"; data = "8.8.8.8"; }
            { name = "tftp-server-name"; data = hostIP; }
          ];
        }
      ];
    };
  };

in
{
  init = {
    name = "kea-init";
    image = defaults.images.keaAdmin;
    command = "/bin/bash -c '/bin/kea-admin db-init pgsql -h localhost -P ${pgPort} -u kea-user -p $KEA_DB_PASSWORD -n kea'";
    successExitCodes = [ 2 ];
    after = [ "postgres" ];
    type = "oneshot";
    needsSecretInterpolation = true;
  };

  service = {
    name = "kea";
    image = defaults.images.keaDhcp4;
    command = "/bin/kea-dhcp4 -c /etc/kea/kea-dhcp4.conf";
    volumes = [
      "kea-dhcp4.conf:/etc/kea/kea-dhcp4.conf:ro"
    ];
    capabilities = [ "NET_RAW" "NET_ADMIN" ];
    after = [ "kea-init" ];
    healthCheck = "bash -ec ': >/dev/tcp/127.0.0.1/${ctrlAgentPort}'";
    type = "service";
  };

  sync = {
    name = "kea-sync";
    image = defaults.images.keaSync;
    command = "/bin/kea-sync";
    environment = {
      KEA_SYNC_LISTEN_ADDR = ":${syncPort}";
      KEA_SYNC_LOG_LEVEL = "info";
      KEA_SYNC_SYNC_INTERVAL = "10s";
      KEA_SYNC_SMD_URL = "http://localhost:${httpPort}";
      KEA_SYNC_KEA_URL = "http://localhost:${ctrlAgentPort}";
      KEA_SYNC_KEA_SERVICES = "dhcp4";
    };
    after = [ "smd" "kea-init" "kea" "http-server" ];
    healthCheck = "curl -fsS http://localhost:${syncPort}/readiness";
    type = "service";
  };

  configFiles = {
    "kea-dhcp4.conf" = keaConfig;
  };
}
