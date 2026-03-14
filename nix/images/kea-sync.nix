# Build kea-sync OCI image from the sibling service workspace.
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
          fmt.Fprintln(os.Stderr, "KEA_SYNC_SRC must point to services/kea-sync when building oci-kea-sync")
          os.Exit(1)
        }
        EOF
      ''
}:

let
  keaSync = pkgs.buildGoModule {
    pname = "kea-sync";
    version = "unstable";
    src = keaSyncSrc;
    vendorHash = "sha256-ycI8Gp4eXoU79kDXaSNWQJPRqZckt5qx+5WafeEfwJ4=";
    subPackages = [ "cmd/kea-sync" ];
    doCheck = false;
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/kea-sync";
  tag = "latest";
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
