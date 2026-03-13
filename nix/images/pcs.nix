# Build PCS (Power Control Service) OCI image from source.
#
# Usage:
#   nix build .#oci-pcs
#   podman load < result
#
{ pkgs
, lib
, pcsSrc ? pkgs.fetchFromGitHub {
    owner = "OpenCHAMI";
    repo = "power-control";
    rev = "main";
    hash = "sha256-CmTGafEqDZg2rpjLdo32qpy5mMHS567OSM0ITco34Sk=";
  }
}:

let
  pcs = pkgs.buildGoModule {
    pname = "power-control";
    version = "unstable";
    src = pcsSrc;
    vendorHash = "sha256-hiCp1uHyJx75sFQGW7L+x6YtYsH9y5ZkL54I6dQdQu0=";
    subPackages = [ "cmd/power-control" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/pcs";
  tag = "local-pcs";
  contents = [
    pcs
    pkgs.bash
    pkgs.cacert
    pkgs.curl
  ];
  extraCommands = ''
    mkdir -p app
    cp -r ${pcsSrc}/configs app/configs
    cp -r ${pcsSrc}/migrations app/migrations
  '';
  config = {
    WorkingDir = "/app";
    Cmd = [ "${pcs}/bin/power-control" ];
  };
}
