# Shared constants for all OpenCHAMI services.
# Single source of truth — mirrors ochami/defaults.py for the Nix world.
{
  ports = {
    smd = 27779;
    bss = 27778;
    postgres = 15432;
    http = 80;
    cloudInit = 27777;
    pcs = 28007;
    keaCtrlAgent = 8000;
    keaSync = 28080;
    stork = 28010;
    storkAgent = 28011;
  };

  databases = {
    superuser = "ochami";
    entries = [
      { name = "hmsds"; user = "smd-user"; passwordEnv = "SMD_DB_PASSWORD"; }
      { name = "bssdb"; user = "bss-user"; passwordEnv = "BSS_DB_PASSWORD"; }
      { name = "kea"; user = "kea-user"; passwordEnv = "KEA_DB_PASSWORD"; }
      { name = "pcsdb"; user = "pcs-user"; passwordEnv = "PCS_DB_PASSWORD"; }
      { name = "stork"; user = "stork-user"; passwordEnv = "STORK_DB_PASSWORD"; }
    ];
  };

  # Default upstream images.  Override via the `images` parameter in profile.nix.
  images = {
    postgres = "docker.io/postgres:11.5-alpine";
    smd = "ghcr.io/openchami/smd:latest";
    bss = "ghcr.io/openchami/bss:latest";
    cloudInit = "ghcr.io/openchami/cloud-init:latest";
    pcs = "ghcr.io/openchami/power-control:latest";
    keaAdmin = "docker.io/jonasal/kea-admin:3.1.4";
    keaDhcp4 = "docker.io/jonasal/kea-dhcp4:3.1.4";
    keaSync = "ghcr.io/openchami/kea-sync:latest";
    nginx = "docker.io/nginx:alpine";
    tftp = "ghcr.io/openchami/tftp:latest";
    storkServer = "docker.io/signalorange/stork:ubuntu24.04-1.19.0";
  };

  # Base images used to build local images.
  baseImages = {
    httpServer = "nginx:1.27.5-alpine";
    redfishEmulator = "python:3.9.21-slim-bookworm";
    tftp = "alpine:3.18.12";
    storkAgent = "jonasal/kea-dhcp4:3.1.4";
    slesBuilder = "opensuse/leap:15.6";
  };

  # Upstream source repos for Go services.
  repos = {
    smd = "https://github.com/openchami/smd.git";
    bss = "https://github.com/openchami/bss.git";
    pcs = "https://github.com/OpenCHAMI/power-control.git";
    cloudInit = "https://github.com/openchami/cloud-init.git";
    keaSync = "https://github.com/aescoubas/kea-sync.git";
  };

  # Container-native paths (used by static generators that don't have access to pkgs).
  # These match the paths inside the upstream OCI images referenced in `images` above.
  containerPaths = {
    keaHooksDir = "/usr/lib/x86_64-linux-gnu/kea/hooks";
    nginxMimeTypes = "/etc/nginx/mime.types";
  };

  # All secret env var names that must appear in secrets.env.
  secretKeys = [
    "POSTGRES_PASSWORD"
    "SMD_DB_PASSWORD"
    "BSS_DB_PASSWORD"
    "KEA_DB_PASSWORD"
    "PCS_DB_PASSWORD"
    "STORK_DB_PASSWORD"
  ];
}
