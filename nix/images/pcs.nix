# Build PCS (Power Control Service) OCI image from source.
#
# Usage:
#   nix build .#oci-pcs
#   podman load < result
#
{ pkgs
, lib
, sourceSpec ? {
    owner = "OpenCHAMI";
    repo = "power-control";
    rev = "main";
    hash = "sha256-CmTGafEqDZg2rpjLdo32qpy5mMHS567OSM0ITco34Sk=";
    vendorHash = "sha256-hiCp1uHyJx75sFQGW7L+x6YtYsH9y5ZkL54I6dQdQu0=";
  }
, pcsSrcOverride ? let
    envSrc = builtins.getEnv "PCS_SRC";
  in
    if envSrc != "" then builtins.path {
      path = envSrc;
      name = "pcs-src";
    } else
      null
, imageName ? "localhost/pcs"
, imageTag ? let
    envTag = builtins.getEnv "PCS_IMAGE_TAG";
  in
    if envTag != "" then envTag else sourceSpec.rev
}:

let
  pcsSrc =
    if pcsSrcOverride != null then
      pcsSrcOverride
    else
      pkgs.fetchFromGitHub {
        inherit (sourceSpec) owner repo rev hash;
      };
  patchedPcsSrc = pkgs.applyPatches {
    name = "pcs-src-with-local-patches";
    src = pcsSrc;
    patches = [ ./patches/pcs-refresh-hsmdata.patch ];
  };
  pcs = pkgs.buildGoModule {
    pname = "power-control";
    version = imageTag;
    src = patchedPcsSrc;
    vendorHash = sourceSpec.vendorHash;
    subPackages = [ "cmd/power-control" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    pcs
    pkgs.bash
    pkgs.cacert
    pkgs.curl
  ];
  extraCommands = ''
    mkdir -p app
    cp -r ${patchedPcsSrc}/configs app/configs
    cp -r ${patchedPcsSrc}/migrations app/migrations
  '';
  config = {
    WorkingDir = "/app";
    Cmd = [ "${pcs}/bin/power-control" ];
  };
}
