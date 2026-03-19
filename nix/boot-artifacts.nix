{ pkgs
, lib
, nixosSystem
, system
}:

let
  xnameIdentityScript = pkgs.writeShellScript "openchami-xname-identity" ''
    set -eu

    xname=""
    for token in $(cat /proc/cmdline); do
      if [ "''${token#xname=}" != "$token" ]; then
        xname="''${token#xname=}"
        break
      fi
    done

    [ -n "$xname" ] || exit 0

    ${pkgs.coreutils}/bin/install -d -m 0755 /run/openchami
    printf '%s\n' "$xname" > /run/openchami/xname
    printf '%s\n' "$xname" > /proc/sys/kernel/hostname
  '';

  xnamePromptScript = ''
    if [ -n "''${PS1:-}" ] && [ -r /run/openchami/xname ]; then
      _openchami_xname="$(cat /run/openchami/xname 2>/dev/null || true)"
      if [ -n "$_openchami_xname" ]; then
        export PS1="[\u@''${_openchami_xname} \W]\\$ "
      fi
      unset _openchami_xname
    fi
  '';

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
        environment.etc."bashrc.local".text = xnamePromptScript;
        systemd.services.openchami-xname-identity = {
          description = "Apply OpenCHAMI xname runtime identity";
          wantedBy = [ "multi-user.target" ];
          before = [
            "getty@tty1.service"
            "serial-getty@ttyS0.service"
          ];
          after = [ "local-fs.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = xnameIdentityScript;
          };
        };
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
