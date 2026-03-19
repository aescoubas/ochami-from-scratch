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
, cloudInitSrcOverride ? let
    envSrc = builtins.getEnv "CLOUD_INIT_SRC";
  in
    if envSrc != "" then builtins.path {
      path = envSrc;
      name = "cloud-init-src";
    } else
      null
, imageName ? "localhost/cloud-init"
, imageTag ? let
    envTag = builtins.getEnv "CLOUD_INIT_IMAGE_TAG";
  in
    if envTag != "" then envTag else sourceSpec.rev
}:

let
  cloudInitSrc =
    if cloudInitSrcOverride != null then
      cloudInitSrcOverride
    else
      pkgs.fetchFromGitHub {
        inherit (sourceSpec) owner repo rev hash;
      };
  cloudInit = pkgs.buildGoModule {
    pname = "cloud-init-server";
    version = imageTag;
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
