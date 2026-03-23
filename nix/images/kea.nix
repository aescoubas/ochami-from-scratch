# Build a local Kea OCI image with DHCPv4, kea-admin, and hook libraries.
#
# Usage:
#   nix build .#oci-kea
#   podman load < result
#
{ pkgs
, imageName ? "localhost/kea"
, imageTag ? builtins.replaceStrings [ "+" "/" ":" "@" " " ] [ "-" "-" "-" "-" "-" ] pkgs.kea.version
}:

let
  # Kea validates that hooks libraries reside under its compile-time prefix.
  # Configs generated with containerPaths.keaHooksDir (Debian path) must be
  # rewritten at startup to use the Nix store path.
  keaEntrypoint = pkgs.writeShellScript "kea-entrypoint" ''
    set -euo pipefail
    nixHooksDir="${pkgs.kea}/lib/kea/hooks"
    # Config files are bind-mounted read-only. Copy to /tmp, rewrite the
    # Debian hooks path to the Nix store path, and adjust the command args.
    mkdir -p /tmp/kea
    for f in /etc/kea/*.conf; do
      [ -f "$f" ] || continue
      ${pkgs.gnused}/bin/sed "s|/usr/lib/x86_64-linux-gnu/kea/hooks|$nixHooksDir|g" "$f" > "/tmp/kea/$(basename "$f")"
    done
    # Replace /etc/kea paths in args with /tmp/kea.
    args=()
    for arg in "$@"; do
      args+=("''${arg//\/etc\/kea\///tmp/kea/}")
    done
    exec "''${args[@]}"
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    pkgs.kea
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.postgresql
    pkgs.gnused
  ];
  extraCommands = ''
    mkdir -p etc/kea
    mkdir -p run/kea
    mkdir -p var/lib/kea
    mkdir -p var/run/kea
  '';
  config = {
    Entrypoint = [ "${keaEntrypoint}" ];
    Cmd = [ "/bin/kea-dhcp4" ];
    ExposedPorts = {
      "67/udp" = { };
      "8000/tcp" = { };
    };
  };
}
