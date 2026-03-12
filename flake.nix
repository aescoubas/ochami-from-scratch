{
  description = "Nix-native OpenCHAMI: generators, OCI images, MCP server, and VM lab";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        lib = pkgs.lib;

        defaults = import ./nix/services/defaults.nix;

        mcpPackage = pkgs.callPackage ./nix/package.nix { };
        checkPackage = pkgs.callPackage ./nix/package.nix {
          runTests = true;
        };
        labSmoke = pkgs.callPackage ./nix/tests/lab-smoke.nix {
          package = mcpPackage;
        };
        devPython = pkgs.python3.withPackages (ps: [
          ps.build
          ps.pip
          ps.pytest
          ps.pytest-mock
        ]);
        apps = {
          default = flake-utils.lib.mkApp {
            drv = mcpPackage;
            exePath = "/bin/ochami-mcp";
          };
          mcp = flake-utils.lib.mkApp {
            drv = mcpPackage;
            exePath = "/bin/ochami-mcp";
          };
        };
      in
      ({
        packages.default = mcpPackage;
        packages.mcp = mcpPackage;

        inherit apps;

        checks.default = checkPackage;

        devShells.default = pkgs.mkShell {
          packages = [
            devPython
            pkgs.nixpkgs-fmt
            mcpPackage
          ];

          shellHook = ''
            export PYTHONPATH="$PWD''${PYTHONPATH:+:$PYTHONPATH}"
          '';
        };

        formatter = pkgs.nixpkgs-fmt;
      } // lib.optionalAttrs pkgs.stdenv.isLinux {
        packages.deploy-profile = pkgs.callPackage ./nix/deploy/profile.nix {
          inherit lib defaults;
        };

        packages.docker-compose-yml = pkgs.callPackage ./nix/generators/docker-compose.nix {
          inherit lib defaults;
        };

        packages.quadlet-units = pkgs.callPackage ./nix/generators/quadlets.nix {
          inherit lib defaults;
        };

        packages.helm-values = pkgs.callPackage ./nix/generators/helm-values.nix {
          inherit lib defaults;
        };

        # OCI image builds (Go services use lib.fakeHash — update with real hashes to build).
        packages.oci-smd = pkgs.callPackage ./nix/images/smd.nix { inherit lib; };
        packages.oci-bss = pkgs.callPackage ./nix/images/bss.nix { inherit lib; };
        packages.oci-pcs = pkgs.callPackage ./nix/images/pcs.nix { inherit lib; };
        packages.oci-cloud-init = pkgs.callPackage ./nix/images/cloud-init.nix { inherit lib; };
        packages.oci-http-server = pkgs.callPackage ./nix/images/http-server.nix { };
        packages.oci-tftp = pkgs.callPackage ./nix/images/tftp.nix { };
        packages.oci-kea-sidecar = pkgs.callPackage ./nix/images/kea-sidecar.nix { };
        packages.oci-redfish-emulator = pkgs.callPackage ./nix/images/redfish-emulator.nix { };

        apps = apps // {
          lab-driver = flake-utils.lib.mkApp {
            drv = labSmoke.driverInteractive;
            exePath = "/bin/nixos-test-driver";
          };
        };

        checks.lab-smoke = labSmoke;
      }));
}
