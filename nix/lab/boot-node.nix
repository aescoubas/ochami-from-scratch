# NixOS VM configuration for the OpenCHAMI lab boot node.
#
# This node gets its IP via DHCP from the controller and can fetch
# boot artifacts over HTTP. In the full lab, it would PXE boot from Kea.
{ pkgs, ... }:
{
  networking = {
    firewall.enable = false;
    hostName = "openchami-bootnode";
    useDHCP = false;
    useNetworkd = true;
    usePredictableInterfaceNames = false;
  };

  virtualisation = {
    memorySize = 768;
    vlans = [ 1 ];
  };

  environment.systemPackages = [
    pkgs.curl
    pkgs.iproute2
  ];

  systemd.network.networks."10-eth0" = {
    name = "eth0";
    networkConfig.DHCP = "ipv4";
    linkConfig.RequiredForOnline = "degraded";
  };

  systemd.network.networks."10-eth1" = {
    name = "eth1";
    address = [ "192.168.100.2/24" ];
    linkConfig.RequiredForOnline = "routable";
    networkConfig.ConfigureWithoutCarrier = true;
  };

  system.stateVersion = "25.11";
}
