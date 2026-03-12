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
    hash = lib.fakeHash;
  }
}:

let
  smd = pkgs.buildGoModule {
    pname = "smd";
    version = "unstable";
    src = smdSrc;
    vendorHash = lib.fakeHash;
    subPackages = [ "cmd/smd" "cmd/smd-init" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/smd";
  tag = "local-smd";
  contents = [
    smd
    pkgs.cacert
    pkgs.curl
  ];
  config = {
    Cmd = [ "${smd}/bin/smd" ];
  };
}
