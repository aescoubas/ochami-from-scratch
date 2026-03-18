# Build kea-sync OCI image from an external checkout, with the source path
# supplied via KEA_SYNC_SRC.
#
# Usage:
#   KEA_SYNC_SRC=/path/to/ochami-dev/services/kea-sync nix build --impure .#oci-kea-sync
#   podman load < result
#
{ pkgs
, keaSyncSrc ? let
    envSrc = builtins.getEnv "KEA_SYNC_SRC";
  in
    if envSrc != "" then builtins.path {
      path = envSrc;
      name = "kea-sync-src";
    } else
      pkgs.runCommand "kea-sync-src-placeholder" { } ''
        mkdir -p "$out/cmd/kea-sync"
        cat > "$out/go.mod" <<'EOF'
        module github.com/OpenCHAMI/kea-sync

        go 1.24.0
        EOF
        cat > "$out/cmd/kea-sync/main.go" <<'EOF'
        package main

        import (
          "fmt"
          "os"
        )

        func main() {
          fmt.Fprintln(os.Stderr, "KEA_SYNC_SRC must point to a checked-out kea-sync repository")
          os.Exit(1)
        }
        EOF
      ''
, imageName ? "localhost/kea-sync"
, imageTag ? "latest"
}:

let
  keaSync = pkgs.buildGoModule {
    pname = "kea-sync";
    version = imageTag;
    src = keaSyncSrc;
    vendorHash = null;
    subPackages = [ "cmd/kea-sync" ];
    doCheck = false;
    prePatch = ''
      sed -i '/^replace github.com\/openchami\/tokensmith\/middleware => \.\.\/\.\.\/shared\/ochami-tokensmith\/middleware$/d' go.mod
    '';
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    keaSync
    pkgs.bash
    pkgs.cacert
    pkgs.curl
  ];
  config = {
    Cmd = [ "${keaSync}/bin/kea-sync" ];
  };
}
