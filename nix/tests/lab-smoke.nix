# NixOS VM-based smoke test for the OpenCHAMI lab.
#
# Verifies:
#   - Controller: dnsmasq + nginx start, correct IP, boot.ipxe served, TFTP listening
#   - Controller: podman is available, MCP server runs
#   - Boot node: gets DHCP lease, fetches boot.ipxe, can ping controller
#
{ pkgs
, package
}:

pkgs.testers.nixosTest {
  name = "openchami-lab-smoke";

  nodes = {
    controller = import ../lab/controller.nix { inherit package; };
    bootnode = import ../lab/boot-node.nix;
  };

  testScript = ''
    start_all()

    # --- Controller checks ---
    controller.wait_for_unit("dnsmasq.service")
    controller.wait_for_unit("nginx.service")
    controller.wait_until_succeeds("ip -4 addr | grep -q '192.168.100.1/24'")
    controller.wait_for_open_port(80)

    # MCP server available
    controller.succeed("ochami-mcp --help >/dev/null")
    controller.succeed("test -f /run/current-system/sw/bin/ochami-mcp")

    # Boot artifacts served via HTTP
    controller.succeed("curl -fsS http://127.0.0.1/boot.ipxe | grep -q '^#!ipxe'")

    # TFTP listening
    controller.succeed("ss -lun | grep -q ':69'")

    # Podman available
    controller.succeed("podman --version >/dev/null")

    # --- Boot node checks ---
    bootnode.wait_until_succeeds("ip -4 addr | grep -q '192.168.100.2/24'")
    bootnode.succeed("curl -fsS http://192.168.100.1/boot.ipxe | grep -q '^#!ipxe'")
    bootnode.succeed("ping -c 1 192.168.100.1")
  '';
}
