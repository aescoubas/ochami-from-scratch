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

pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    pkgs.kea
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.postgresql
  ];
  # pkgs.kea exposes the DHCP hook libraries under /lib/kea/hooks.
  extraCommands = ''
    mkdir -p etc/kea
    mkdir -p run/kea
    mkdir -p var/lib/kea
    mkdir -p var/run/kea
  '';
  config = {
    Cmd = [ "/bin/kea-dhcp4" ];
    ExposedPorts = {
      "67/udp" = { };
      "8000/tcp" = { };
    };
  };
}
