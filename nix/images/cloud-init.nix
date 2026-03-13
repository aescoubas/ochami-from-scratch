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
    hash = "sha256-TxEYFe9Kkp2i9bmx/+BGMJgDfiklTi2J0kV4ydk31Ns=";
  }
}:

let
  cloudInit = pkgs.buildGoModule {
    pname = "cloud-init-server";
    version = "unstable";
    src = cloudInitSrc;
    vendorHash = "sha256-ZpOjgzPU3dksbHpe9QTH+uGRQvg6clZUjfLEOLfUyfw=";
    subPackages = [ "cmd/cloud-init-server" ];
    buildInputs = [ pkgs.duckdb ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/cloud-init";
  tag = "local-cloud-init";
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
