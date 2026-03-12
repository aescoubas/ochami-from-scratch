# Build Redfish emulator OCI image.
#
# Usage:
#   nix build .#oci-redfish-emulator
#   podman load < result
#
{ pkgs }:

let
  emulatorSrc = ../../../ochami-helm/redfish-emulator;

  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.flask
    ps.libvirt
  ]);
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/redfish-emulator";
  tag = "latest";
  contents = [
    pythonEnv
    pkgs.cacert
  ];
  extraCommands = ''
    mkdir -p app
    cp ${emulatorSrc}/emulator.py emulator.py
  '';
  config = {
    Cmd = [ "${pythonEnv}/bin/python" "-u" "/emulator.py" ];
  };
}
