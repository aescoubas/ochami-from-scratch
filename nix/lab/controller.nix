# NixOS VM configuration for the OpenCHAMI lab controller.
#
# Installs the generated OpenCHAMI systemd units declaratively and starts the
# in-guest stack once networking is online. Host access still comes through the
# forwarded management interface, while the PXE-facing services bind to eth1.
{ package ? null
, bootArtifacts
, labDeployProfile
, labSecrets
, labRenderedConfigFiles
, labLocalImageArchives
, labImageRefs
}:
{ lib, pkgs, ... }:

let
  renderedConfigEtc =
    lib.mapAttrs'
      (name: path: lib.nameValuePair "openchami/configs/${name}" { source = path; })
      labRenderedConfigFiles;
  labImageLoadScript = pkgs.writeScript "openchami-lab-load-images.sh" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    load_image() {
      local archive="$1"
      local ref="$2"

      if ${pkgs.podman}/bin/podman image exists "$ref"; then
        return 0
      fi

      ${pkgs.podman}/bin/podman load -i "$archive"
    }

    ${lib.concatStringsSep "\n    " [
      "load_image ${lib.escapeShellArg (toString labLocalImageArchives.smd)} ${lib.escapeShellArg labImageRefs.smd}"
      "load_image ${lib.escapeShellArg (toString labLocalImageArchives.bss)} ${lib.escapeShellArg labImageRefs.bss}"
      "load_image ${lib.escapeShellArg (toString labLocalImageArchives.pcs)} ${lib.escapeShellArg labImageRefs.pcs}"
      "load_image ${lib.escapeShellArg (toString labLocalImageArchives.cloudInit)} ${lib.escapeShellArg labImageRefs.cloudInit}"
      "load_image ${lib.escapeShellArg (toString labLocalImageArchives.kea)} ${lib.escapeShellArg labImageRefs.keaDhcp4}"
      "load_image ${lib.escapeShellArg (toString labLocalImageArchives.httpServer)} ${lib.escapeShellArg labImageRefs.nginx}"
      "load_image ${lib.escapeShellArg (toString labLocalImageArchives.tftp)} ${lib.escapeShellArg labImageRefs.tftp}"
    ]}
  '';
in
{
  networking = {
    firewall.enable = false;
    hostName = "openchami-controller";
    useDHCP = false;
    useNetworkd = true;
    usePredictableInterfaceNames = false;
  };

  virtualisation = {
    # The controller preloads several local OCI archives before activating the
    # in-guest stack, so the direct-QEMU path needs more than the tiny default
    # qemu-vm root disk image.
    diskSize = 16384;
    memorySize = 2048;
    vlans = [ 1 ];
    podman.enable = true;
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
  };

  users.users.lab = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "lab";
  };

  environment.systemPackages =
    [
      pkgs.curl
      pkgs.iproute2
      pkgs.podman
      pkgs.jq
      labDeployProfile
      bootArtifacts.package
    ]
    ++ lib.optional (package != null) package;

  environment.etc =
    {
      "openchami/secrets.env".source = labSecrets;
    }
    // renderedConfigEtc;

  systemd.packages = [ labDeployProfile ];

  systemd.services.openchami-lab-load-images = {
    description = "Load local OpenCHAMI OCI images into the controller VM";
    wantedBy = [ "multi-user.target" ];
    before = [ "openchami-lab-activate.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = labImageLoadScript;
    };
  };

  systemd.services.openchami-lab-activate = {
    description = "Start OpenCHAMI inside the controller VM";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" "openchami-lab-load-images.service" ];
    after = [ "network-online.target" "openchami-lab-load-images.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.systemd}/bin/systemctl start ochami.target";
      ExecStop = "${pkgs.systemd}/bin/systemctl stop ochami.target";
    };
  };

  systemd.network.networks."10-eth0" = {
    name = "eth0";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "degraded";
  };

  systemd.network.networks."10-eth1" = {
    name = "eth1";
    address = [ "192.168.100.1/24" ];
    linkConfig.RequiredForOnline = "degraded";
    networkConfig.ConfigureWithoutCarrier = true;
  };

  system.stateVersion = "25.11";
}
