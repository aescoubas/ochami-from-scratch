# Build Kea sidecar (SMD sync) OCI image.
#
# Usage:
#   nix build .#oci-kea-sidecar
#   podman load < result
#
{ pkgs
, sidecarSrc
}:

let

  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.requests
    ps.psycopg2
  ]);
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/kea-sidecar";
  tag = "latest";
  contents = [
    pythonEnv
    pkgs.cacert
  ];
  extraCommands = ''
    mkdir -p app
    cp ${sidecarSrc}/smd_sync.py app/smd_sync.py
  '';
  config = {
    Cmd = [ "${pythonEnv}/bin/python" "-u" "/app/smd_sync.py" ];
  };
}
