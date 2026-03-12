# NixOS VM configuration for the OpenCHAMI lab controller.
#
# Hosts all OpenCHAMI services via Podman containers + deploy-profile systemd units.
# Also runs dnsmasq for DHCP/TFTP and nginx for boot artifacts (as a lightweight
# fallback for the containerised stack).
{ package }:
{ pkgs, ... }:

let
  bootArtifacts = pkgs.runCommand "openchami-lab-boot-artifacts" { } ''
    mkdir -p "$out"
    cat > "$out/boot.ipxe" <<'EOF'
    #!ipxe
    echo OpenCHAMI Nix Lab Smoke
    shell
    EOF
  '';
in
{
  networking = {
    firewall.enable = false;
    useDHCP = false;
    useNetworkd = true;
    usePredictableInterfaceNames = false;
  };

  virtualisation = {
    memorySize = 2048;
    vlans = [ 1 ];
    podman.enable = true;
  };

  environment.systemPackages = [
    package
    pkgs.curl
    pkgs.iproute2
    pkgs.podman
    pkgs.jq
  ];

  # Lightweight dnsmasq for DHCP/TFTP (used until the full Kea stack is running).
  services.dnsmasq = {
    enable = true;
    settings = {
      "bind-interfaces" = true;
      "dhcp-boot" = "boot.ipxe";
      "dhcp-option" = "3,192.168.100.1";
      "dhcp-range" = "192.168.100.50,192.168.100.150,255.255.255.0,1h";
      "enable-tftp" = true;
      "interface" = "eth1";
      "tftp-root" = toString bootArtifacts;
    };
  };

  # Static nginx serving boot artifacts.
  services.nginx = {
    enable = true;
    virtualHosts."lab-controller" = {
      default = true;
      root = bootArtifacts;
    };
  };

  systemd.network.networks."10-eth1" = {
    name = "eth1";
    address = [ "192.168.100.1/24" ];
    networkConfig.ConfigureWithoutCarrier = true;
  };
}
