# Build SMD (State Management Daemon) OCI image from source.
#
# Usage:
#   nix build .#oci-smd
#   podman load < result
#
{ pkgs
, lib
, sourceSpec ? {
    owner = "openchami";
    repo = "smd";
    rev = "main";
    hash = "sha256-SKAao/ib26e2I0QKprxQjUcxD9gFKdFHUwJpGfLTLkc=";
    vendorHash = "sha256-Gqvn+GMctybEOhLsXo1/2TewpGiO7c0IO/YFC2TPWKQ=";
  }
, smdSrcOverride ? let
    envSrc = builtins.getEnv "SMD_SRC";
  in
    if envSrc != "" then builtins.path {
      path = envSrc;
      name = "smd-src";
    } else
      null
, imageName ? "localhost/smd"
, imageTag ? let
    envTag = builtins.getEnv "SMD_IMAGE_TAG";
  in
    if envTag != "" then envTag else sourceSpec.rev
}:

let
  smdSrc =
    if smdSrcOverride != null then
      smdSrcOverride
    else
      pkgs.fetchFromGitHub {
        inherit (sourceSpec) owner repo rev hash;
      };
  smd = pkgs.buildGoModule {
    pname = "smd";
    version = imageTag;
    src = smdSrc;
    vendorHash = sourceSpec.vendorHash;
    subPackages = [ "cmd/smd" "cmd/smd-init" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    smd
    pkgs.bash
    pkgs.cacert
    pkgs.curl
  ];
  extraCommands = ''
    mkdir -p persistent_migrations
    cp -r ${smdSrc}/migrations/. persistent_migrations/
  '';
  config = {
    Cmd = [ "${smd}/bin/smd" ];
  };
}
