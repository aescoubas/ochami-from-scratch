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
        labGuestSystem = "x86_64-linux";
        labGuestPkgs = import nixpkgs {
          system = labGuestSystem;
        };

        defaults = import ./nix/services/defaults.nix;

        mcpPackage = pkgs.callPackage ./nix/package.nix { };
        labGuestMcpPackage = labGuestPkgs.callPackage ./nix/package.nix { };
        checkPackage = pkgs.callPackage ./nix/package.nix {
          runTests = true;
        };
        hostPkgs = pkgs;
        labSystems = import ./nix/lab/systems.nix {
          inherit nixpkgs hostPkgs;
          guestSystem = labGuestSystem;
          package = null;
        };
        labControllerSystem = labSystems.controller.config.system.build.toplevel;
        labBootNodeSystem = labSystems.bootnode.config.system.build.toplevel;
        labControllerVm = labSystems.controller.config.system.build.vm;
        labBootNodeVm = labSystems.bootnode.config.system.build.vm;
        labSmoke = labGuestPkgs.callPackage ./nix/tests/lab-smoke.nix {
          package = labGuestMcpPackage;
        };
        bootArtifacts =
          if pkgs.stdenv.isLinux then
            import ./nix/boot-artifacts.nix {
              inherit pkgs system;
              lib = pkgs.lib;
              nixosSystem = nixpkgs.lib.nixosSystem;
            }
          else
            null;
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
      {
        packages = {
          default = mcpPackage;
          mcp = mcpPackage;
          "lab-controller-system" = labControllerSystem;
          "lab-boot-node-system" = labBootNodeSystem;
          "lab-controller-vm" = labControllerVm;
          "lab-boot-node-vm" = labBootNodeVm;
        } // lib.optionalAttrs pkgs.stdenv.isLinux {
          "boot-artifacts" = bootArtifacts.package;
          "deploy-profile" = pkgs.callPackage ./nix/deploy/profile.nix {
            inherit lib defaults bootArtifacts;
            imageOverrides = defaults.localImageOverrides;
          };
          "docker-compose-yml" = pkgs.callPackage ./nix/generators/docker-compose.nix {
            inherit lib defaults bootArtifacts;
            imageOverrides = defaults.localImageOverrides;
          };
          "quadlet-units" = pkgs.callPackage ./nix/generators/quadlets.nix {
            inherit lib defaults bootArtifacts;
            imageOverrides = defaults.localImageOverrides;
          };
          "helm-values" = pkgs.callPackage ./nix/generators/helm-values.nix {
            inherit lib defaults;
            imageOverrides = defaults.localImageOverrides;
          };
          "oci-smd" = pkgs.callPackage ./nix/images/smd.nix { inherit lib; };
          "oci-bss" = pkgs.callPackage ./nix/images/bss.nix { inherit lib; };
          "oci-pcs" = pkgs.callPackage ./nix/images/pcs.nix { inherit lib; };
          "oci-cloud-init" = pkgs.callPackage ./nix/images/cloud-init.nix { inherit lib; };
          "oci-kea" = pkgs.callPackage ./nix/images/kea.nix { };
          "oci-http-server" = pkgs.callPackage ./nix/images/http-server.nix { };
          "oci-tftp" = pkgs.callPackage ./nix/images/tftp.nix { };
          "oci-kea-sync" = pkgs.callPackage ./nix/images/kea-sync.nix { };
          "oci-redfish-emulator" = pkgs.callPackage ./nix/images/redfish-emulator.nix {
            emulatorSrc = ./ochami-helm/redfish-emulator;
          };
        };

        apps = apps // lib.optionalAttrs pkgs.stdenv.isLinux {
          "lab-driver" = flake-utils.lib.mkApp {
            drv = labSmoke.driverInteractive;
            exePath = "/bin/nixos-test-driver";
          };
        };

        checks = {
          default = checkPackage;
        } // lib.optionalAttrs pkgs.stdenv.isLinux {
          "lab-smoke" = labSmoke;
        };

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
      }
      );
}
