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
        rawProfiles = {
          official = import ./nix/profiles/official.nix;
          dev = import ./nix/profiles/dev.nix;
        };
        resolveProfile = rawProfile: pkgs.callPackage ./nix/profiles/resolve.nix {
          inherit lib defaults;
          profile = rawProfile;
        };
        profiles = lib.mapAttrs (_: rawProfile: resolveProfile rawProfile) rawProfiles;

        mcpPackage = pkgs.callPackage ./nix/package.nix { };
        labGuestMcpPackage = labGuestPkgs.callPackage ./nix/package.nix { };
        checkPackage = pkgs.callPackage ./nix/package.nix {
          runTests = true;
        };
        selectedBootImage =
          let
            value = builtins.getEnv "OPENCHAMI_TEST_NODE_IMAGE";
          in
          if value != "" then value else "nixos";
        bootArtifactsFor = image:
          import ./nix/boot-artifacts.nix {
            inherit pkgs system;
            lib = pkgs.lib;
            nixosSystem = nixpkgs.lib.nixosSystem;
            bootImage = image;
          };
        hostPkgs = pkgs;
        labSystems = import ./nix/lab/systems.nix {
          inherit nixpkgs hostPkgs;
          guestSystem = labGuestSystem;
          package = null;
          rawOfficialProfile = rawProfiles.official;
          bootImage = selectedBootImage;
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
            bootArtifactsFor selectedBootImage
          else
            null;
        bootArtifactsByImage =
          if pkgs.stdenv.isLinux then
            lib.genAttrs [ "almalinux" "opensuse" "ubuntu" "nixos" ] bootArtifactsFor
          else
            { };
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
        profilePackages =
          if pkgs.stdenv.isLinux then
            lib.mapAttrs (profileName: profile:
              let
                envOr = name: fallback:
                  let
                    value = builtins.getEnv name;
                  in
                  if value != "" then value else fallback;
                ociImageArchives = {
                  smd = pkgs.callPackage ./nix/images/smd.nix {
                    inherit lib;
                    sourceSpec = profile.sources.smd;
                    imageTag = envOr "SMD_IMAGE_TAG" profile.refs.smd;
                  };
                  bss = pkgs.callPackage ./nix/images/bss.nix {
                    inherit lib;
                    sourceSpec = profile.sources.bss;
                    imageTag = envOr "BSS_IMAGE_TAG" profile.refs.bss;
                  };
                  pcs = pkgs.callPackage ./nix/images/pcs.nix {
                    inherit lib;
                    sourceSpec = profile.sources.pcs;
                    imageTag = envOr "PCS_IMAGE_TAG" profile.refs.pcs;
                  };
                  cloudInit = pkgs.callPackage ./nix/images/cloud-init.nix {
                    inherit lib;
                    sourceSpec = profile.sources.cloudInit;
                    imageTag = envOr "CLOUD_INIT_IMAGE_TAG" profile.refs.cloudInit;
                  };
                  kea = pkgs.callPackage ./nix/images/kea.nix {
                    imageTag = profile.refs.kea;
                  };
                  httpServer = pkgs.callPackage ./nix/images/http-server.nix {
                    imageTag = profile.refs.httpServer;
                  };
                  libvirtBmc = pkgs.callPackage ./nix/images/libvirt-bmc.nix { };
                  tftp = pkgs.callPackage ./nix/images/tftp.nix {
                    imageTag = profile.refs.tftp;
                  };
                  keaSync = pkgs.callPackage ./nix/images/kea-sync.nix {
                    imageTag = envOr "KEA_SYNC_IMAGE_TAG" profile.refs.keaSync;
                  };
                };
              in
              {
                "boot-artifacts" = bootArtifacts.package;
                "deploy-profile" = pkgs.callPackage ./nix/deploy/profile.nix {
                  inherit lib defaults bootArtifacts profile;
                };
                "docker-compose-yml" = pkgs.callPackage ./nix/generators/docker-compose.nix {
                  inherit lib defaults bootArtifacts profile;
                };
                "quadlet-units" = pkgs.callPackage ./nix/generators/quadlets.nix {
                  inherit lib defaults bootArtifacts profile;
                };
                "helm-values" = pkgs.callPackage ./nix/generators/helm-values.nix {
                  inherit lib defaults profile;
                };
                "oci-smd" = ociImageArchives.smd;
                "oci-bss" = ociImageArchives.bss;
                "oci-pcs" = ociImageArchives.pcs;
                "oci-cloud-init" = ociImageArchives.cloudInit;
                "oci-kea" = ociImageArchives.kea;
                "oci-http-server" = ociImageArchives.httpServer;
                "oci-libvirt-bmc" = ociImageArchives.libvirtBmc;
                "oci-tftp" = ociImageArchives.tftp;
                "oci-kea-sync" = ociImageArchives.keaSync;
                "oci-images" = pkgs.callPackage ./nix/images/bundle.nix {
                  inherit lib profileName;
                  images = ociImageArchives;
                };
              }) profiles
          else
            { };
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
          "boot-artifacts" = profilePackages.official."boot-artifacts";
          "boot-artifacts-official" = profilePackages.official."boot-artifacts";
          "boot-artifacts-dev" = profilePackages.dev."boot-artifacts";
          "boot-artifacts-almalinux" = bootArtifactsByImage.almalinux.package;
          "boot-artifacts-opensuse" = bootArtifactsByImage.opensuse.package;
          "boot-artifacts-ubuntu" = bootArtifactsByImage.ubuntu.package;
          "boot-artifacts-nixos" = bootArtifactsByImage.nixos.package;
          "deploy-profile" = profilePackages.official."deploy-profile";
          "deploy-profile-official" = profilePackages.official."deploy-profile";
          "deploy-profile-dev" = profilePackages.dev."deploy-profile";
          "docker-compose-yml" = profilePackages.official."docker-compose-yml";
          "docker-compose-yml-official" = profilePackages.official."docker-compose-yml";
          "docker-compose-yml-dev" = profilePackages.dev."docker-compose-yml";
          "quadlet-units" = profilePackages.official."quadlet-units";
          "quadlet-units-official" = profilePackages.official."quadlet-units";
          "quadlet-units-dev" = profilePackages.dev."quadlet-units";
          "helm-values" = profilePackages.official."helm-values";
          "helm-values-official" = profilePackages.official."helm-values";
          "helm-values-dev" = profilePackages.dev."helm-values";
          "oci-smd" = profilePackages.official."oci-smd";
          "oci-smd-official" = profilePackages.official."oci-smd";
          "oci-smd-dev" = profilePackages.dev."oci-smd";
          "oci-bss" = profilePackages.official."oci-bss";
          "oci-bss-official" = profilePackages.official."oci-bss";
          "oci-bss-dev" = profilePackages.dev."oci-bss";
          "oci-pcs" = profilePackages.official."oci-pcs";
          "oci-pcs-official" = profilePackages.official."oci-pcs";
          "oci-pcs-dev" = profilePackages.dev."oci-pcs";
          "oci-cloud-init" = profilePackages.official."oci-cloud-init";
          "oci-cloud-init-official" = profilePackages.official."oci-cloud-init";
          "oci-cloud-init-dev" = profilePackages.dev."oci-cloud-init";
          "oci-kea" = profilePackages.official."oci-kea";
          "oci-kea-official" = profilePackages.official."oci-kea";
          "oci-kea-dev" = profilePackages.dev."oci-kea";
          "oci-http-server" = profilePackages.official."oci-http-server";
          "oci-http-server-official" = profilePackages.official."oci-http-server";
          "oci-http-server-dev" = profilePackages.dev."oci-http-server";
          "oci-libvirt-bmc" = profilePackages.official."oci-libvirt-bmc";
          "oci-libvirt-bmc-official" = profilePackages.official."oci-libvirt-bmc";
          "oci-libvirt-bmc-dev" = profilePackages.dev."oci-libvirt-bmc";
          "oci-tftp" = profilePackages.official."oci-tftp";
          "oci-tftp-official" = profilePackages.official."oci-tftp";
          "oci-tftp-dev" = profilePackages.dev."oci-tftp";
          "oci-kea-sync" = profilePackages.official."oci-kea-sync";
          "oci-kea-sync-official" = profilePackages.official."oci-kea-sync";
          "oci-kea-sync-dev" = profilePackages.dev."oci-kea-sync";
          "oci-images" = profilePackages.official."oci-images";
          "oci-images-official" = profilePackages.official."oci-images";
          "oci-images-dev" = profilePackages.dev."oci-images";
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
