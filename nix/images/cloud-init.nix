# Build cloud-init server OCI image from source.
#
# Usage:
#   nix build .#oci-cloud-init
#   podman load < result
#
{ pkgs
, lib
, sourceSpec ? {
    owner = "openchami";
    repo = "cloud-init";
    rev = "main";
    hash = "sha256-TxEYFe9Kkp2i9bmx/+BGMJgDfiklTi2J0kV4ydk31Ns=";
    vendorHash = "sha256-ZpOjgzPU3dksbHpe9QTH+uGRQvg6clZUjfLEOLfUyfw=";
  }
, imageName ? "localhost/cloud-init"
, imageTag ? sourceSpec.rev
}:

let
  cloudInitSrc = pkgs.fetchFromGitHub {
    inherit (sourceSpec) owner repo rev hash;
  };
  cloudInit = pkgs.buildGoModule {
    pname = "cloud-init-server";
    version = sourceSpec.rev;
    src = cloudInitSrc;
    vendorHash = sourceSpec.vendorHash;
    subPackages = [ "cmd/cloud-init-server" ];
    buildInputs = [ pkgs.duckdb ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    cloudInit
    pkgs.bash
    pkgs.cacert
    pkgs.curl
    pkgs.iproute2
  ];
  config = {
    Cmd = [ "${cloudInit}/bin/cloud-init-server" ];
  };
}
