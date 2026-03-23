{ nixpkgs
, guestSystem
, hostPkgs
, rawOfficialProfile
, bootImage ? "nixos"
, package ? null
}:

let
  guestPkgs = import nixpkgs {
    system = guestSystem;
  };
  defaults = import ../services/defaults.nix;
  resolvedOfficialProfile = guestPkgs.callPackage ../profiles/resolve.nix {
    lib = guestPkgs.lib;
    inherit defaults;
    profile = rawOfficialProfile;
  };
  labProfile = resolvedOfficialProfile // {
    containerServiceIds = builtins.filter (id: id != "kea-sync") resolvedOfficialProfile.containerServiceIds;
  };
  labBootArtifacts = import ../boot-artifacts.nix {
    pkgs = guestPkgs;
    lib = guestPkgs.lib;
    nixosSystem = nixpkgs.lib.nixosSystem;
    system = guestSystem;
    inherit bootImage;
  };
  labLocalImageArchives = {
    smd = guestPkgs.callPackage ../images/smd.nix {
      lib = guestPkgs.lib;
      sourceSpec = labProfile.sources.smd;
      imageTag = labProfile.refs.smd;
    };
    bss = guestPkgs.callPackage ../images/bss.nix {
      lib = guestPkgs.lib;
      sourceSpec = labProfile.sources.bss;
      imageTag = labProfile.refs.bss;
    };
    pcs = guestPkgs.callPackage ../images/pcs.nix {
      lib = guestPkgs.lib;
      sourceSpec = labProfile.sources.pcs;
      imageTag = labProfile.refs.pcs;
    };
    cloudInit = guestPkgs.callPackage ../images/cloud-init.nix {
      lib = guestPkgs.lib;
      sourceSpec = labProfile.sources.cloudInit;
      imageTag = labProfile.refs.cloudInit;
    };
    kea = guestPkgs.callPackage ../images/kea.nix {
      imageTag = labProfile.refs.kea;
    };
    httpServer = guestPkgs.callPackage ../images/http-server.nix {
      imageTag = labProfile.refs.httpServer;
    };
    tftp = guestPkgs.callPackage ../images/tftp.nix {
      imageTag = labProfile.refs.tftp;
    };
  };
  labDeployProfile = guestPkgs.callPackage ../deploy/profile.nix {
    lib = guestPkgs.lib;
    inherit defaults;
    profile = labProfile;
    hostIP = "192.168.100.1";
    pxeInterface = "eth1";
    dhcpRange = "192.168.100.50 - 192.168.100.150";
    pxeCidr = "24";
    bootArtifacts = labBootArtifacts;
    containerTool = "${guestPkgs.podman}/bin/podman";
  };
  labSecrets = import ./secrets.nix {
    pkgs = guestPkgs;
  };
  labKea = import ../services/kea.nix {
    defaults = defaults // { images = labProfile.runtimeImages; };
    hostIP = "192.168.100.1";
    pxeInterface = "eth1";
    dhcpRange = "192.168.100.50 - 192.168.100.150";
    pxeCidr = "24";
  };
  labNginx = import ../services/nginx.nix {
    lib = guestPkgs.lib;
    defaults = defaults // { images = labProfile.runtimeImages; };
    hostIP = "192.168.100.1";
    enableStork = false;
    bootArtifacts = labBootArtifacts;
  };
  labConfigTemplates = labKea.configFiles // labNginx.configFiles;
  renderLabConfig = name: content:
    let templateFile = guestPkgs.writeText "${name}-template" content;
    in guestPkgs.runCommand "openchami-lab-${name}" {
      nativeBuildInputs = [ guestPkgs.gettext ];
    } ''
      set -euo pipefail
      . ${labSecrets}
      export $(cut -d= -f1 ${labSecrets} | grep -v '^#')
      vars="$(cut -d= -f1 ${labSecrets} | grep -v '^#' | sed 's/^/$/; s/$/ /' | tr -d '\n')"
      envsubst "$vars" < ${templateFile} > "$out"
    '';
  labRenderedConfigFiles = guestPkgs.lib.mapAttrs renderLabConfig labConfigTemplates;
  qemuVmModule = { modulesPath, ... }: {
    imports = [
      "${modulesPath}/virtualisation/qemu-vm.nix"
    ];
  };

  hostPkgsModule = {
    virtualisation.host.pkgs = hostPkgs;
  };

  mkSystem = modules: nixpkgs.lib.nixosSystem {
    system = guestSystem;
    modules = [ qemuVmModule hostPkgsModule { system.stateVersion = "25.11"; } ] ++ modules;
  };
in
{
  controller = mkSystem [
    (import ./controller.nix {
      inherit package;
      bootArtifacts = labBootArtifacts;
      inherit labDeployProfile labSecrets labRenderedConfigFiles labLocalImageArchives;
      labImageRefs = {
        smd = labProfile.imageOverrides.smd;
        bss = labProfile.imageOverrides.bss;
        pcs = labProfile.imageOverrides.pcs;
        cloudInit = labProfile.imageOverrides.cloudInit;
        keaDhcp4 = labProfile.imageOverrides.keaDhcp4;
        nginx = labProfile.imageOverrides.nginx;
        tftp = labProfile.imageOverrides.tftp;
      };
    })
  ];

  bootnode = mkSystem [
    ./boot-node.nix
  ];
}
