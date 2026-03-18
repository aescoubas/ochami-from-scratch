{ nixpkgs
, guestSystem
, hostPkgs
, package ? null
}:

let
  guestPkgs = import nixpkgs {
    system = guestSystem;
  };
  defaults = import ../services/defaults.nix;
  labBootArtifacts = import ../boot-artifacts.nix {
    pkgs = guestPkgs;
    lib = guestPkgs.lib;
    nixosSystem = nixpkgs.lib.nixosSystem;
    system = guestSystem;
  };
  labImageOverrides = {
    smd = defaults.localImageOverrides.smd;
    bss = defaults.localImageOverrides.bss;
    pcs = defaults.localImageOverrides.pcs;
    cloudInit = defaults.localImageOverrides.cloudInit;
    keaAdmin = defaults.localImageOverrides.keaAdmin;
    keaDhcp4 = defaults.localImageOverrides.keaDhcp4;
    nginx = defaults.localImageOverrides.nginx;
    tftp = defaults.localImageOverrides.tftp;
  };
  labLocalImageArchives = {
    smd = guestPkgs.callPackage ../images/smd.nix { lib = guestPkgs.lib; };
    bss = guestPkgs.callPackage ../images/bss.nix { lib = guestPkgs.lib; };
    pcs = guestPkgs.callPackage ../images/pcs.nix { lib = guestPkgs.lib; };
    cloudInit = guestPkgs.callPackage ../images/cloud-init.nix { lib = guestPkgs.lib; };
    kea = guestPkgs.callPackage ../images/kea.nix { };
    httpServer = guestPkgs.callPackage ../images/http-server.nix { };
    tftp = guestPkgs.callPackage ../images/tftp.nix { };
  };
  labDeployProfile = guestPkgs.callPackage ../deploy/profile.nix {
    lib = guestPkgs.lib;
    inherit defaults;
    hostIP = "192.168.100.1";
    pxeInterface = "eth1";
    dhcpRange = "192.168.100.50 - 192.168.100.150";
    pxeCidr = "24";
    bootArtifacts = labBootArtifacts;
    enableKeaSync = false;
    imageOverrides = labImageOverrides;
    containerTool = "${guestPkgs.podman}/bin/podman";
  };
  labSecrets = import ./secrets.nix {
    pkgs = guestPkgs;
  };
  labKea = import ../services/kea.nix {
    pkgs = guestPkgs;
    inherit defaults;
    hostIP = "192.168.100.1";
    pxeInterface = "eth1";
    dhcpRange = "192.168.100.50 - 192.168.100.150";
    pxeCidr = "24";
  };
  labNginx = import ../services/nginx.nix {
    pkgs = guestPkgs;
    lib = guestPkgs.lib;
    inherit defaults;
    hostIP = "192.168.100.1";
    enableStork = false;
    bootArtifacts = labBootArtifacts;
  };
  labConfigTemplates = labKea.configFiles // labNginx.configFiles;
  renderLabConfig = name: path:
    guestPkgs.runCommand "openchami-lab-${name}" {
      nativeBuildInputs = [ guestPkgs.gettext ];
    } ''
      set -euo pipefail
      . ${labSecrets}
      export $(cut -d= -f1 ${labSecrets} | grep -v '^#')
      vars="$(cut -d= -f1 ${labSecrets} | grep -v '^#' | sed 's/^/$/; s/$/ /' | tr -d '\n')"
      envsubst "$vars" < ${path} > "$out"
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
    modules = [ qemuVmModule hostPkgsModule ] ++ modules;
  };
in
{
  controller = mkSystem [
    (import ./controller.nix {
      inherit package;
      bootArtifacts = labBootArtifacts;
      inherit labDeployProfile labSecrets labRenderedConfigFiles labLocalImageArchives;
      labImageRefs = {
        smd = labImageOverrides.smd;
        bss = labImageOverrides.bss;
        pcs = labImageOverrides.pcs;
        cloudInit = labImageOverrides.cloudInit;
        keaDhcp4 = labImageOverrides.keaDhcp4;
        nginx = labImageOverrides.nginx;
        tftp = labImageOverrides.tftp;
      };
    })
  ];

  bootnode = mkSystem [
    ./boot-node.nix
  ];
}
