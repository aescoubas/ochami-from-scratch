# Build BSS (Boot Script Service) OCI image from source.
#
# Usage:
#   nix build .#oci-bss
#   podman load < result
#
{ pkgs
, lib
, sourceSpec ? {
    owner = "openchami";
    repo = "bss";
    rev = "main";
    hash = "sha256-NGgLB/2o6KW1ZPAlbITtlRSurja93lLBjyHVkhmDGaE=";
    vendorHash = "sha256-TXBznp95gkHKc76UgwQJ+xQHD8HfAC7nbfse0YrjH9A=";
  }
, imageName ? "localhost/bss"
, imageTag ? sourceSpec.rev
}:

let
  bssSrc = pkgs.fetchFromGitHub {
    inherit (sourceSpec) owner repo rev hash;
  };
  bss = pkgs.buildGoModule {
    pname = "bss";
    version = sourceSpec.rev;
    src = bssSrc;
    vendorHash = sourceSpec.vendorHash;
    subPackages = [ "cmd/boot-script-service" "cmd/bss-init" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    bss
    pkgs.bash
    pkgs.cacert
    pkgs.curl
  ];
  extraCommands = ''
    mkdir -p migrations
    cp -r ${bssSrc}/migrations/. migrations/
  '';
  config = {
    Cmd = [ "${bss}/bin/boot-script-service" ];
  };
}
