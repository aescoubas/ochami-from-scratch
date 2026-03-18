# Build SMD (State Management Daemon) OCI image from source.
#
# Usage:
#   nix build .#oci-smd
#   podman load < result
#
{ pkgs
, lib
, sourceSpec ? {
    owner = "openchami";
    repo = "smd";
    rev = "main";
    hash = "sha256-SKAao/ib26e2I0QKprxQjUcxD9gFKdFHUwJpGfLTLkc=";
    vendorHash = "sha256-Gqvn+GMctybEOhLsXo1/2TewpGiO7c0IO/YFC2TPWKQ=";
  }
, imageName ? "localhost/smd"
, imageTag ? sourceSpec.rev
}:

let
  smdSrc = pkgs.fetchFromGitHub {
    inherit (sourceSpec) owner repo rev hash;
  };
  smd = pkgs.buildGoModule {
    pname = "smd";
    version = sourceSpec.rev;
    src = smdSrc;
    vendorHash = sourceSpec.vendorHash;
    subPackages = [ "cmd/smd" "cmd/smd-init" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
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
