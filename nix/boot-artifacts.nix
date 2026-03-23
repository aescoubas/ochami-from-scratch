{ pkgs
, lib
, nixosSystem
, system
, bootImage ? "nixos"
}:

let
  supportedBootImages = [
    "almalinux"
    "opensuse"
    "ubuntu"
    "nixos"
  ];

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

  nixosKernelPath =
    "${netbootSystem.config.system.build.kernel}/${netbootSystem.config.system.boot.loader.kernelFile}";
  nixosInitrdPath = "${netbootSystem.config.system.build.netbootRamdisk}/initrd";
  nixosKernelArgs = lib.concatStringsSep " " (
    [ "init=${netbootSystem.config.system.build.toplevel}/init" ]
    ++ netbootSystem.config.boot.kernelParams
  );

  ubuntuNetboot = pkgs.fetchurl {
    url = "https://releases.ubuntu.com/noble/ubuntu-24.04.4-netboot-amd64.tar.gz";
    hash = "sha256-8A092FoSmXSPK7m9iBSEsnDeYnAyZnq5dBpMST172zE=";
  };

  almaLinuxKernel = pkgs.fetchurl {
    url = "https://repo.almalinux.org/almalinux/9.7/BaseOS/x86_64/os/images/pxeboot/vmlinuz";
    hash = "sha256-YPVp5Gam729Nufh6NrrPKG4o8Gm71LzI9wl+0acaYAA=";
  };

  almaLinuxInitrd = pkgs.fetchurl {
    url = "https://repo.almalinux.org/almalinux/9.7/BaseOS/x86_64/os/images/pxeboot/initrd.img";
    hash = "sha256-MCJLhkBCCImv0QKd6Cf9ACYWA6QCTIEyKP/BGrCwznY=";
  };

  openSuseKernel = pkgs.fetchurl {
    url = "https://download.opensuse.org/distribution/leap/15.6/repo/oss/boot/x86_64/loader/linux";
    hash = "sha256-XEBqHY8YeQNQV/Qkx63yaV0IvlOStAs+Sf7kv9cgYys=";
  };

  openSuseInitrd = pkgs.fetchurl {
    url = "https://download.opensuse.org/distribution/leap/15.6/repo/oss/boot/x86_64/loader/initrd";
    hash = "sha256-HU1kIjiQxBirQ/ftMGA3xYRhjsOMKIRadJoF0c47Pyk=";
  };

  imageCatalog = {
    almalinux = rec {
      id = "almalinux";
      label = "AlmaLinux 9.7 PXE installer";
      relativeDir = "artifacts/almalinux";
      kernelFile = "vmlinuz";
      initrdFile = "initrd.img";
      kernelArgs = lib.concatStringsSep " " [
        "ip=dhcp"
        "inst.repo=https://repo.almalinux.org/almalinux/9.7/BaseOS/x86_64/os/"
        "inst.text"
        "console=ttyS0,115200n8"
        "console=tty0"
      ];
      consoleReadyPattern = "AlmaLinux|anaconda|installation program|login:";
      installCommands = ''
        mkdir -p "$out/${relativeDir}"
        cp ${almaLinuxKernel} "$out/${relativeDir}/${kernelFile}"
        cp ${almaLinuxInitrd} "$out/${relativeDir}/${initrdFile}"
      '';
    };

    opensuse = rec {
      id = "opensuse";
      label = "openSUSE Leap 15.6 installer";
      relativeDir = "artifacts/opensuse";
      kernelFile = "linux";
      initrdFile = "initrd";
      kernelArgs = lib.concatStringsSep " " [
        "install=https://download.opensuse.org/distribution/leap/15.6/repo/oss/"
        "ifcfg=dhcp"
        "textmode=1"
        "console=ttyS0,115200"
        "console=tty0"
      ];
      consoleReadyPattern = "openSUSE|linuxrc|YaST|login:";
      installCommands = ''
        mkdir -p "$out/${relativeDir}"
        cp ${openSuseKernel} "$out/${relativeDir}/${kernelFile}"
        cp ${openSuseInitrd} "$out/${relativeDir}/${initrdFile}"
      '';
    };

    ubuntu = rec {
      id = "ubuntu";
      label = "Ubuntu Server 24.04.4 netboot installer";
      relativeDir = "artifacts/ubuntu";
      kernelFile = "linux";
      initrdFile = "initrd";
      kernelArgs = lib.concatStringsSep " " [
        "root=/dev/ram0"
        "ramdisk_size=1500000"
        "ip=dhcp"
        "iso-url=https://releases.ubuntu.com/noble/ubuntu-24.04.4-live-server-amd64.iso"
        "console=ttyS0,115200n8"
        "console=tty0"
        "---"
      ];
      consoleReadyPattern = "Ubuntu Server|Subiquity|ubuntu login:|login:";
      installCommands = ''
        workdir="$TMPDIR/ubuntu-netboot"
        mkdir -p "$workdir" "$out/${relativeDir}"
        ${pkgs.gnutar}/bin/tar -xzf ${ubuntuNetboot} -C "$workdir"
        cp "$workdir/amd64/linux" "$out/${relativeDir}/${kernelFile}"
        cp "$workdir/amd64/initrd" "$out/${relativeDir}/${initrdFile}"
      '';
    };

    nixos = rec {
      id = "nixos";
      label = "NixOS netboot runtime";
      relativeDir = "artifacts/nixos";
      kernelFile = "vmlinuz-lts";
      initrdFile = "initramfs-lts";
      kernelArgs = nixosKernelArgs;
      consoleReadyPattern = "Welcome to NixOS kexec|login:|nixos@";
      installCommands = ''
        mkdir -p "$out/${relativeDir}"
        cp ${nixosKernelPath} "$out/${relativeDir}/${kernelFile}"
        cp ${nixosInitrdPath} "$out/${relativeDir}/${initrdFile}"
      '';
    };
  };

  selectedImage =
    if builtins.hasAttr bootImage imageCatalog then
      imageCatalog.${bootImage}
    else
      throw "unsupported test node image '${bootImage}' (expected one of: ${lib.concatStringsSep ", " supportedBootImages})";

  metadataJson = builtins.toJSON {
    selected = {
      inherit (selectedImage)
        id
        label
        relativeDir
        kernelFile
        initrdFile
        kernelArgs
        consoleReadyPattern;
    };
    supported = supportedBootImages;
  };

  package = pkgs.runCommand "ochami-boot-artifacts-${selectedImage.id}" { } ''
    set -euo pipefail
    mkdir -p "$out"
    ${selectedImage.installCommands}
    cat > "$out/${selectedImage.relativeDir}/kernel-params" <<'EOF'
    ${selectedImage.kernelArgs}
    EOF
    cat > "$out/metadata.json" <<'EOF'
    ${metadataJson}
    EOF
  '';
in
{
  inherit bootImage package supportedBootImages;
  selected = selectedImage;
  inherit (selectedImage)
    id
    label
    relativeDir
    kernelFile
    initrdFile
    kernelArgs
    consoleReadyPattern;
}
