# Build BSS (Boot Script Service) OCI image from source.
#
# Usage:
#   nix build .#oci-bss
#   podman load < result
#
{ pkgs
, lib
, bssSrc ? pkgs.fetchFromGitHub {
    owner = "openchami";
    repo = "bss";
    rev = "main";
    hash = lib.fakeHash;
  }
}:

let
  bss = pkgs.buildGoModule {
    pname = "bss";
    version = "unstable";
    src = bssSrc;
    vendorHash = lib.fakeHash;
    subPackages = [ "cmd/boot-script-service" "cmd/bss-init" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/bss";
  tag = "local-bss";
  contents = [
    bss
    pkgs.cacert
    pkgs.curl
  ];
  config = {
    Cmd = [ "${bss}/bin/boot-script-service" ];
  };
}
