# Build SMD (State Management Daemon) OCI image from source.
#
# Usage:
#   nix build .#oci-smd
#   podman load < result
#
{ pkgs
, lib
, smdSrc ? pkgs.fetchFromGitHub {
    owner = "openchami";
    repo = "smd";
    rev = "main";
    hash = "sha256-SKAao/ib26e2I0QKprxQjUcxD9gFKdFHUwJpGfLTLkc=";
  }
}:

let
  smd = pkgs.buildGoModule {
    pname = "smd";
    version = "unstable";
    src = smdSrc;
    vendorHash = "sha256-Gqvn+GMctybEOhLsXo1/2TewpGiO7c0IO/YFC2TPWKQ=";
    subPackages = [ "cmd/smd" "cmd/smd-init" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/smd";
  tag = "local-smd";
  contents = [
    smd
    pkgs.bash
    pkgs.cacert
    pkgs.curl
  ];
  extraCommands = ''
    mkdir -p persistent_migrations
    cp -r ${smdSrc}/migrations/. persistent_migrations/
  '';
  config = {
    Cmd = [ "${smd}/bin/smd" ];
  };
}
