{ pkgs
, lib
, nixosSystem
, system
}:

let
  netbootSystem = nixosSystem {
    inherit system;
    modules = [
      "${pkgs.path}/nixos/modules/installer/netboot/netboot-minimal.nix"
      ({ ... }: {
        networking.hostName = "ochami-netboot";
        boot.kernelParams = [
          "console=ttyS0,115200n8"
          "console=tty0"
          "ip=dhcp"
        ];
      })
    ];
  };

  kernelPath =
    "${netbootSystem.config.system.build.kernel}/${netbootSystem.config.system.boot.loader.kernelFile}";
  initrdPath = "${netbootSystem.config.system.build.netbootRamdisk}/initrd";
  kernelArgs = lib.concatStringsSep " " (
    [ "init=${netbootSystem.config.system.build.toplevel}/init" ]
    ++ netbootSystem.config.boot.kernelParams
  );

  package = pkgs.runCommand "ochami-boot-artifacts" { } ''
    mkdir -p "$out/artifacts/opensuse"
    cp ${kernelPath} "$out/artifacts/opensuse/vmlinuz-lts"
    cp ${initrdPath} "$out/artifacts/opensuse/initramfs-lts"
    cat > "$out/artifacts/opensuse/kernel-params" <<'EOF'
    ${kernelArgs}
    EOF
  '';
in
{
  inherit package kernelArgs;
  relativeDir = "artifacts/opensuse";
  kernelFile = "vmlinuz-lts";
  initrdFile = "initramfs-lts";
}
