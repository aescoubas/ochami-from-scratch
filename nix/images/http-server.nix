# Build HTTP server (nginx) OCI image.
#
# Usage:
#   nix build .#oci-http-server
#   podman load < result
#
{ pkgs }:

pkgs.dockerTools.buildLayeredImage {
  name = "localhost/http-server";
  tag = "latest";
  contents = [
    pkgs.nginx
    pkgs.coreutils
    pkgs.bash
  ];
  extraCommands = ''
    mkdir -p etc/nginx/conf.d
    mkdir -p usr/share/nginx/html
    mkdir -p var/log/nginx
    mkdir -p var/cache/nginx
    mkdir -p run
  '';
  config = {
    Cmd = [ "${pkgs.nginx}/bin/nginx" "-g" "daemon off;" ];
    ExposedPorts = {
      "80/tcp" = { };
    };
  };
}
