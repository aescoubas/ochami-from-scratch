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
    hash = lib.fakeHash;
  }
}:

let
  pcs = pkgs.buildGoModule {
    pname = "power-control";
    version = "unstable";
    src = pcsSrc;
    vendorHash = lib.fakeHash;
    subPackages = [ "cmd/power-control" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/pcs";
  tag = "local-pcs";
  contents = [
    pcs
    pkgs.cacert
    pkgs.curl
  ];
  config = {
    Cmd = [ "${pcs}/bin/power-control" ];
  };
}
