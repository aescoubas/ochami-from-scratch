# Build cloud-init server OCI image from source.
#
# Usage:
#   nix build .#oci-cloud-init
#   podman load < result
#
{ pkgs
, lib
, cloudInitSrc ? pkgs.fetchFromGitHub {
    owner = "openchami";
    repo = "cloud-init";
    rev = "main";
    hash = lib.fakeHash;
  }
}:

let
  cloudInit = pkgs.buildGoModule {
    pname = "cloud-init-server";
    version = "unstable";
    src = cloudInitSrc;
    vendorHash = lib.fakeHash;
    subPackages = [ "cmd/cloud-init-server" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/cloud-init";
  tag = "local-cloud-init";
  contents = [
    cloudInit
    pkgs.cacert
    pkgs.curl
    pkgs.iproute2
  ];
  config = {
    Cmd = [ "${cloudInit}/bin/cloud-init-server" ];
  };
}
