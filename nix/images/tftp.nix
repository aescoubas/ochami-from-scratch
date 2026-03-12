# Build TFTP server OCI image.
#
# Usage:
#   nix build .#oci-tftp
#   podman load < result
#
{ pkgs }:

pkgs.dockerTools.buildLayeredImage {
  name = "localhost/tftp";
  tag = "latest";
  contents = [
    pkgs.tftp-hpa
    pkgs.coreutils
    pkgs.bash
  ];
  extraCommands = ''
    mkdir -p srv/tftp
  '';
  config = {
    Cmd = [ "${pkgs.tftp-hpa}/bin/in.tftpd" "--foreground" "--secure" "/srv/tftp" ];
    ExposedPorts = {
      "69/udp" = { };
    };
  };
}
