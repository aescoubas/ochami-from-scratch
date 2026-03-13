# Kea DHCP4 — db-init oneshot + long-running service + sidecar.
# Config file has $KEA_DB_PASSWORD placeholder for envsubst at activation.
{ pkgs, defaults, hostIP, pxeInterface, dhcpRange, pxeCidr }:

let
  pgPort = toString defaults.ports.postgres;
  httpPort = toString defaults.ports.http;
  smdPort = toString defaults.ports.smd;

  keaConfig = builtins.toJSON {
    Dhcp4 = {
      interfaces-config.interfaces = [ pxeInterface ];
      control-socket = {
        socket-type = "unix";
        socket-name = "/kea/sockets/kea4-ctrl-socket";
      };
      hooks-libraries = [
        { library = "/usr/local/lib/kea/hooks/libdhcp_pgsql.so"; }
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

  sidecar = {
    name = "kea-sidecar";
    image = defaults.images.keaSidecar;
    command = "python -u /app/smd_sync.py";
    environment = {
      SMD_URL = "https://localhost:${smdPort}";
      SMD_VERIFY_TLS = "false";
      DB_NAME = "kea";
      DB_USER = "kea-user";
      DB_HOST = "localhost";
      DB_PORT = pgPort;
    };
    secretEnvKeys = [ "KEA_DB_PASSWORD" ];
    envMapping = { DB_PASS = "KEA_DB_PASSWORD"; };
    after = [ "smd" "kea-init" "kea" ];
    type = "service";
  };

  configFile = keaConfigFile;
}
