# Kea DHCP4 - db-init oneshot + DHCP service + control agent + kea-sync.
# Config file has $KEA_DB_PASSWORD placeholder for envsubst at activation.
{ pkgs, defaults, hostIP, pxeInterface, dhcpRange, pxeCidr }:

let
  pgPort = toString defaults.ports.postgres;
  httpPort = toString defaults.ports.http;
  ctrlAgentPort = toString defaults.ports.keaCtrlAgent;
  syncPort = toString defaults.ports.keaSync;

  keaConfig = builtins.toJSON {
    Dhcp4 = {
      interfaces-config.interfaces = [ pxeInterface ];
      control-socket = {
        socket-type = "unix";
        socket-name = "/kea/sockets/kea4-ctrl-socket";
      };
      hooks-libraries = [
        { library = "/usr/local/lib/kea/hooks/libdhcp_pgsql.so"; }
        { library = "/usr/local/lib/kea/hooks/libdhcp_host_cmds.so"; }
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

  keaConfigFile = pkgs.writeText "kea-dhcp4.conf" keaConfig;
  ctrlAgentConfigFile = pkgs.writeText "kea-ctrl-agent.conf" (builtins.toJSON {
    "Control-agent" = {
      http-host = "127.0.0.1";
      http-port = defaults.ports.keaCtrlAgent;
      control-sockets = {
        dhcp4 = {
          socket-type = "unix";
          socket-name = "/kea/sockets/kea4-ctrl-socket";
        };
      };
    };
  });
in
{
  init = {
    name = "kea-init";
    image = defaults.images.keaAdmin;
    command = "db-init pgsql -h localhost -P ${pgPort} -u kea-user -p $KEA_DB_PASSWORD -n kea";
    after = [ "postgres" ];
    type = "oneshot";
    needsSecretInterpolation = true;
  };

  service = {
    name = "kea";
    image = defaults.images.keaDhcp4;
    command = "-c /etc/kea/kea-dhcp4.conf";
    volumes = [
      "kea-dhcp4.conf:/etc/kea/kea-dhcp4.conf:ro"
      "ochami-kea-sockets:/kea/sockets"
    ];
    capabilities = [ "NET_RAW" "NET_ADMIN" ];
    after = [ "kea-init" ];
    healthCheck = "test -S /kea/sockets/kea4-ctrl-socket";
    type = "service";
  };

  controlAgent = {
    name = "kea-ctrl-agent";
    image = defaults.images.keaCtrlAgent;
    command = "-c /etc/kea/kea-ctrl-agent.conf";
    volumes = [
      "kea-ctrl-agent.conf:/etc/kea/kea-ctrl-agent.conf:ro"
      "ochami-kea-sockets:/kea/sockets"
    ];
    after = [ "kea" ];
    healthCheck = "test -S /kea/sockets/kea4-ctrl-socket";
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
    after = [ "smd" "kea-init" "kea" "kea-ctrl-agent" "http-server" ];
    healthCheck = "curl -fsS http://localhost:${syncPort}/readiness";
    type = "service";
  };

  configFiles = {
    "kea-dhcp4.conf" = keaConfigFile;
    "kea-ctrl-agent.conf" = ctrlAgentConfigFile;
  };
}
