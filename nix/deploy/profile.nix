# Build a deploy profile: systemd units + config files + activate script.
#
# Usage:
#   nix build .#deploy-profile
#   sudo ./result/bin/activate
#
{ pkgs
, lib
, defaults
, hostIP ? "192.168.100.1"
, pxeInterface ? "eth1"
, dhcpRange ? "192.168.100.50 - 192.168.100.150"
, pxeCidr ? "24"
, enableStork ? false
, imageOverrides ? { }
, containerTool ? "podman"
}:

let
  # Merge image overrides into defaults.
  images = defaults.images // imageOverrides;
  effectiveDefaults = defaults // { inherit images; };

  # Import all service definitions.
  postgres = import ../services/postgres.nix { inherit pkgs; defaults = effectiveDefaults; };
  smd = import ../services/smd.nix { defaults = effectiveDefaults; };
  bss = import ../services/bss.nix { inherit pkgs; defaults = effectiveDefaults; inherit hostIP; };
  cloudInit = import ../services/cloud-init.nix { defaults = effectiveDefaults; };
  pcs = import ../services/pcs.nix { defaults = effectiveDefaults; };
  kea = import ../services/kea.nix { inherit pkgs; defaults = effectiveDefaults; inherit hostIP pxeInterface dhcpRange pxeCidr; };
  nginx = import ../services/nginx.nix { inherit pkgs lib; defaults = effectiveDefaults; inherit hostIP enableStork; };
  tftp = import ../services/tftp.nix { defaults = effectiveDefaults; };

  # Collect all container services (init + long-running).
  allServices = [
    postgres.service
    smd.init
    smd.service
    bss.init
    bss.service
    cloudInit.service
    pcs.init
    pcs.service
    kea.init
    kea.service
    kea.sidecar
    nginx.service
    tftp.service
  ];

  # The BSS boot-defaults oneshot is a script, not a container.
  bssBootDefaults = bss.bootDefaults;

  # --- Systemd unit generation ---

  envToFlags = env:
    lib.concatStringsSep " \\\n    " (
      lib.mapAttrsToList (k: v: "--env ${k}=${lib.escapeShellArg v}") env
    );

  volumeToFlag = v:
    let
      parts = lib.splitString ":" v;
      src = builtins.head parts;
      rest = lib.concatStringsSep ":" (builtins.tail parts);
      # Named volumes (podman manages them) or absolute paths (nix store) pass through.
      # Short names are config files mapped from /etc/openchami/configs/.
      isNamed = lib.hasPrefix "ochami-" v;
      isAbsolute = lib.hasPrefix "/" src;
    in
    if isNamed || isAbsolute then
      "--volume ${v}"
    else
      "--volume /etc/openchami/configs/${src}:${rest}";

  capsToFlags = svc:
    lib.concatStringsSep " " (
      map (c: "--cap-add=${c}") (svc.capabilities or [ ])
    );

  envMappingToFlags = svc:
    let mapping = svc.envMapping or { };
    in lib.concatStringsSep " \\\n    " (
      lib.mapAttrsToList (containerVar: secretVar:
        "--env ${containerVar}=$(grep '^${secretVar}=' /etc/openchami/secrets.env | cut -d= -f2-)"
      ) mapping
    );

  makeContainerUnit = svc:
    let
      unitName = "ochami-${svc.name}";
      afterUnits = map (d: "ochami-${d}.service") svc.after;
      afterStr = lib.concatStringsSep " " afterUnits;
      isOneshot = svc.type == "oneshot";
      env = svc.environment or { };
      volumes = svc.volumes or [ ];
      command = svc.command or "";

      # Build the podman run arguments as a list, then join.
      runArgs = [
        "--rm"
        "--name ${unitName}"
        "--network=host"
        "--env-file /etc/openchami/secrets.env"
      ]
      ++ lib.mapAttrsToList (k: v: "--env ${k}=${lib.escapeShellArg v}") env
      ++ lib.mapAttrsToList (containerVar: secretVar:
        "--env ${containerVar}=$(grep '^${secretVar}=' /etc/openchami/secrets.env | cut -d= -f2-)"
      ) (svc.envMapping or { })
      ++ map volumeToFlag volumes
      ++ map (c: "--cap-add=${c}") (svc.capabilities or [ ])
      ++ lib.optional (svc ? healthCheck)
        "--health-cmd='${svc.healthCheck}' --health-interval=5s";

      execStart = "${containerTool} run ${lib.concatStringsSep " \\\n    " runArgs} \\\n    ${svc.image} ${command}";

      unitSections = lib.concatStringsSep "\n" (lib.filter (s: s != "") [
        "[Unit]"
        "Description=OpenCHAMI ${svc.name}"
        (lib.optionalString (afterStr != "") "After=${afterStr}")
        (lib.optionalString (afterStr != "") "Requires=${afterStr}")
        ""
        "[Service]"
        "Type=${if isOneshot then "oneshot" else "exec"}"
        (lib.optionalString isOneshot "RemainAfterExit=yes")
        "Restart=${if isOneshot then "no" else "on-failure"}"
        "TimeoutStartSec=300"
        "ExecStartPre=-${containerTool} rm -f ${unitName}"
        "ExecStart=${execStart}"
        (lib.optionalString (!isOneshot) "ExecStop=${containerTool} stop ${unitName}")
        ""
        "[Install]"
        "WantedBy=ochami.target"
      ]);
    in
    pkgs.writeText "${unitName}.service" unitSections;

  # BSS boot-defaults is a script-based oneshot, not a container.
  bssBootDefaultsUnit = pkgs.writeText "ochami-bss-boot-defaults.service" ''
    [Unit]
    Description=OpenCHAMI BSS boot defaults registration
    After=ochami-bss.service
    Requires=ochami-bss.service

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=${bssBootDefaults.script}

    [Install]
    WantedBy=ochami.target
  '';

  ochamiTarget = pkgs.writeText "ochami.target" ''
    [Unit]
    Description=OpenCHAMI Services
    Wants=${lib.concatStringsSep " " (
      map (s: "ochami-${s.name}.service") allServices
      ++ [ "ochami-bss-boot-defaults.service" ]
    )}

    [Install]
    WantedBy=multi-user.target
  '';

  # --- Config files that need envsubst for secrets ---
  configFiles = {
    "kea-dhcp4.conf" = kea.configFile;
  } // nginx.configFiles;

  # --- Secrets template ---
  secretsTemplate = pkgs.writeText "secrets.env.template" (
    lib.concatStringsSep "\n" (map (k: "${k}=") defaults.secretKeys)
    + "\n"
  );

  # --- Activate script ---
  activateScript = pkgs.writeScript "activate" ''
    #!/usr/bin/env bash
    set -euo pipefail
    PROFILE="$(cd "$(dirname "$0")/.." && pwd)"
    SECRETS="''${OPENCHAMI_SECRETS:-/etc/openchami/secrets.env}"

    if [ ! -f "$SECRETS" ]; then
      echo "ERROR: secrets file not found: $SECRETS"
      echo "Create it from: $PROFILE/etc/openchami/secrets.env.template"
      exit 1
    fi

    # Place config files, substituting secret placeholders
    mkdir -p /etc/openchami/configs
    for f in "$PROFILE"/etc/openchami/configs/*; do
      . "$SECRETS"
      export $(cut -d= -f1 "$SECRETS" | grep -v '^#')
      ${pkgs.envsubst}/bin/envsubst < "$f" > "/etc/openchami/configs/$(basename "$f")"
    done

    # Install systemd units
    ln -sf "$PROFILE"/etc/openchami/systemd/*.service /etc/systemd/system/
    ln -sf "$PROFILE"/etc/openchami/systemd/ochami.target /etc/systemd/system/

    # Start
    systemctl daemon-reload
    systemctl start ochami.target
    echo "OpenCHAMI activated."
  '';

  # --- Deactivate script ---
  deactivateScript = pkgs.writeScript "deactivate" ''
    #!/usr/bin/env bash
    set -euo pipefail
    systemctl stop ochami.target 2>/dev/null || true
    rm -f /etc/systemd/system/ochami-*.service /etc/systemd/system/ochami.target
    systemctl daemon-reload
    echo "OpenCHAMI deactivated."
  '';

in
pkgs.runCommand "ochami-deploy-profile" { } ''
  mkdir -p $out/{bin,etc/openchami/{systemd,configs}}

  # Systemd units
  ${lib.concatStringsSep "\n" (map (svc:
    "cp ${makeContainerUnit svc} $out/etc/openchami/systemd/ochami-${svc.name}.service"
  ) allServices)}
  cp ${bssBootDefaultsUnit} $out/etc/openchami/systemd/ochami-bss-boot-defaults.service
  cp ${ochamiTarget} $out/etc/openchami/systemd/ochami.target

  # Config files (with secret placeholders for envsubst)
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: path:
    "cp ${path} $out/etc/openchami/configs/${name}"
  ) configFiles)}

  # Secrets template
  cp ${secretsTemplate} $out/etc/openchami/secrets.env.template

  # Scripts
  cp ${activateScript} $out/bin/activate
  cp ${deactivateScript} $out/bin/deactivate
''
