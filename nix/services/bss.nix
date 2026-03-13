# Boot Script Service (BSS) — init + service + boot-defaults oneshot.
{ pkgs, defaults, hostIP }:

let
  pgPort = toString defaults.ports.postgres;
  httpPort = toString defaults.ports.http;
  bssPort = toString defaults.ports.bss;
  smdPort = toString defaults.ports.smd;
  artifactsUrl = "http://${hostIP}:${httpPort}/artifacts/opensuse";
in
{
  init = {
    name = "bss-init";
    image = defaults.images.bss;
    command = "/bin/bss-init --postgres-migrations /migrations/postgres";
    environment = {
      BSS_INSECURE = "true";
      BSS_DBSTEP = "2";
      BSS_DBHOST = "localhost";
      BSS_DBPORT = pgPort;
      BSS_DBNAME = "bssdb";
      BSS_DBUSER = "bss-user";
      BSS_DBOPTS = "sslmode=disable";
    };
    secretEnvKeys = [ "BSS_DB_PASSWORD" ];
    envMapping = { BSS_DBPASS = "BSS_DB_PASSWORD"; };
    after = [ "postgres" ];
    type = "oneshot";
  };

  service = {
    name = "bss";
    image = defaults.images.bss;
    environment = {
      HSM_URL = "https://localhost:${smdPort}";
      BSS_INSECURE = "true";
      BSS_DEBUG = "true";
      BSS_DBHOST = "localhost";
      BSS_DBPORT = pgPort;
      BSS_DBNAME = "bssdb";
      BSS_DBUSER = "bss-user";
      BSS_DBOPTS = "sslmode=disable";
      BSS_JWKS_URL = "";
      BSS_IPXE_SERVER = hostIP;
      BSS_CHAIN_PROTO = "http";
      BSS_ENDPOINT = "localhost";
      BSS_ADVERTISE_ADDRESS = hostIP;
      NFD_URL = "http://${hostIP}:${httpPort}/hmi/v1/subscribe";
    };
    secretEnvKeys = [ "BSS_DB_PASSWORD" ];
    envMapping = { BSS_DBPASS = "BSS_DB_PASSWORD"; };
    healthCheck = "curl -sf http://localhost:${bssPort}/boot/v1/bootparameters";
    after = [ "smd" "bss-init" ];
    type = "service";
  };

  # Oneshot that registers default boot parameters after BSS is healthy.
  bootDefaults = {
    name = "bss-boot-defaults";
    type = "oneshot";
    after = [ "bss" ];
    script = pkgs.writeScript "bss-boot-defaults.sh" ''
      #!/bin/bash
      set -euo pipefail
      BSS_URL="http://localhost:${bssPort}/boot/v1/bootparameters"
      for i in $(seq 1 30); do
        if curl -sf "$BSS_URL" >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      curl -sf -X PUT -H 'Content-Type: application/json' "$BSS_URL" -d '{
        "hosts": ["Default"],
        "kernel": "${artifactsUrl}/vmlinuz-lts",
        "initrd": "${artifactsUrl}/initramfs-lts",
        "params": "console=ttyS0 ip=dhcp rd.neednet=1 root=live:${artifactsUrl}/rootfs.squashfs"
      }'
    '';
  };
}
