# Build a deploy profile: systemd units + config files + activate script.
#
# Usage:
#   nix build .#deploy-profile
#   sudo ./result/bin/activate
#
{ pkgs
, lib
, defaults
, profile
, hostIP ? "192.168.100.1"
, pxeInterface ? "virbr-ochami"
, dhcpRange ? "192.168.100.50 - 192.168.100.150"
, pxeCidr ? "24"
, enableStork ? false
, bootArtifacts
, containerTool ? "podman"
}:

let
  imageOverrides = profile.imageOverrides;
  stack = import ../services/catalog.nix {
    inherit pkgs lib;
    inherit defaults profile hostIP pxeInterface dhcpRange pxeCidr enableStork bootArtifacts;
  };

  # Collect all container services (init + long-running).
  allServices = stack.allContainerServices;

  # The BSS boot-defaults oneshot is a script, not a container.
  bssBootDefaults = builtins.head stack.allScriptServices;

  # --- Systemd unit generation ---

  volumeToSpec = v:
    let
      parts = lib.splitString ":" v;
      src = builtins.head parts;
      rest = lib.concatStringsSep ":" (builtins.tail parts);
      isNamed = lib.hasPrefix "ochami-" v;
      isAbsolute = lib.hasPrefix "/" src;
      isRelative = lib.hasPrefix "./" src;
      hasSlash = lib.hasInfix "/" src;
    in
    if isNamed || isAbsolute then v
    else if isRelative then "/etc/openchami/${lib.removePrefix "./" src}:${rest}"
    else if hasSlash then "/etc/openchami/${src}:${rest}"
    else "/etc/openchami/configs/${src}:${rest}";

  makeContainerRunner = svc:
    let
      unitName = "ochami-${svc.name}";
      isOneshot = svc.type == "oneshot";
      env = svc.environment or { };
      volumes = svc.volumes or [ ];
      command = svc.command or "";
      needsPostgresWait = isOneshot && lib.elem "postgres" (svc.after or [ ]);
      successExitCodes = svc.successExitCodes or [ ];
      successExitCodesStr = lib.concatMapStringsSep " " toString successExitCodes;
      staticEnvLines = lib.mapAttrsToList (k: v:
        "args+=( --env ${lib.escapeShellArg "${k}=${v}"} )"
      ) env;
      mappedEnvLines = lib.mapAttrsToList (containerVar: secretVar:
        ''args+=( --env "${containerVar}=''${${secretVar}:?${secretVar} is required}" )''
      ) (svc.envMapping or { });
      volumeLines = map (v:
        "args+=( --volume ${lib.escapeShellArg (volumeToSpec v)} )"
      ) volumes;
      capabilityLines = map (c:
        "args+=( --cap-add=${lib.escapeShellArg c} )"
      ) (svc.capabilities or [ ]);
      healthLines =
        if svc ? healthCheck then
          [
            "args+=( --health-cmd ${lib.escapeShellArg svc.healthCheck} )"
            "args+=( --health-interval 5s )"
          ]
        else
          [ ];
      commandSuffix = lib.optionalString (command != "") " ${command}";
    in
    pkgs.writeScript "ochami-${svc.name}-run" ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      . /etc/openchami/secrets.env

      wait_for_tcp() {
        local host="$1"
        local port="$2"
        local attempts="$3"
        local try=0

        until ( : >"/dev/tcp/$host/$port" ) >/dev/null 2>&1; do
          try=$((try + 1))
          if [ "$try" -ge "$attempts" ]; then
            echo "Timed out waiting for $host:$port" >&2
            return 1
          fi
          ${pkgs.coreutils}/bin/sleep 2
        done
      }

      args=(
        run
        --rm
        --name
        ${unitName}
        --network=host
        --env-file
        /etc/openchami/secrets.env
      )
      ${lib.concatStringsSep "\n      " staticEnvLines}
      ${lib.concatStringsSep "\n      " mappedEnvLines}
      ${lib.concatStringsSep "\n      " volumeLines}
      ${lib.concatStringsSep "\n      " capabilityLines}
      ${lib.concatStringsSep "\n      " healthLines}
      ${lib.optionalString needsPostgresWait "wait_for_tcp 127.0.0.1 ${toString defaults.ports.postgres} 120"}
      ${lib.optionalString (isOneshot && successExitCodes != [ ]) ''
      set +e
      ${containerTool} "''${args[@]}" ${lib.escapeShellArg svc.image}${commandSuffix}
      status=$?
      set -e
      case " ${successExitCodesStr} " in
        *" $status "*) exit 0 ;;
      esac
      exit "$status"
      ''}
      ${lib.optionalString (!(isOneshot && successExitCodes != [ ])) ''
      exec ${containerTool} "''${args[@]}" ${lib.escapeShellArg svc.image}${commandSuffix}
      ''}
    '';

  makeContainerUnit = svc:
    let
      unitName = "ochami-${svc.name}";
      afterUnits = map (d: "ochami-${d}.service") svc.after;
      afterStr = lib.concatStringsSep " " afterUnits;
      isOneshot = svc.type == "oneshot";

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
        "ExecStart=${makeContainerRunner svc}"
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
  # configFiles are now content strings (not store paths).
  configFiles = stack.configFiles;
  supportFiles = stack.supportFiles;

  # --- Secrets template ---
  secretsTemplate = pkgs.writeText "secrets.env.template" (
    lib.concatStringsSep "\n" (map (k: "${k}=") defaults.secretKeys)
    + "\n"
  );

  # --- Activate script ---
  activateScript = pkgs.writeScript "activate" ''
    #!${pkgs.bash}/bin/bash
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
    . "$SECRETS"
    export $(cut -d= -f1 "$SECRETS" | grep -v '^#')
    envsubst_vars="$(cut -d= -f1 "$SECRETS" | grep -v '^#' | sed 's/^/$/; s/$/ /' | tr -d '\n')"
    for f in "$PROFILE"/etc/openchami/configs/*; do
      ${pkgs.envsubst}/bin/envsubst "$envsubst_vars" < "$f" > "/etc/openchami/configs/$(basename "$f")"
    done

    # Place support files (pg-init scripts, etc.)
    if [ -d "$PROFILE"/etc/openchami/pg-init ]; then
      mkdir -p /etc/openchami/pg-init
      cp -r "$PROFILE"/etc/openchami/pg-init/* /etc/openchami/pg-init/
    fi

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
    #!${pkgs.bash}/bin/bash
    set -euo pipefail
    systemctl stop ochami.target 2>/dev/null || true
    rm -f /etc/systemd/system/ochami-*.service /etc/systemd/system/ochami.target
    systemctl daemon-reload
    echo "OpenCHAMI deactivated."
  '';

in
pkgs.runCommand "ochami-deploy-profile" { } ''
  mkdir -p $out/{bin,etc/openchami/{systemd,configs},lib/systemd/system}

  # Systemd units
  ${lib.concatStringsSep "\n" (map (svc:
    ''
      cp ${makeContainerUnit svc} $out/etc/openchami/systemd/ochami-${svc.name}.service
      cp ${makeContainerUnit svc} $out/lib/systemd/system/ochami-${svc.name}.service
    ''
  ) allServices)}
  cp ${bssBootDefaultsUnit} $out/etc/openchami/systemd/ochami-bss-boot-defaults.service
  cp ${bssBootDefaultsUnit} $out/lib/systemd/system/ochami-bss-boot-defaults.service
  cp ${ochamiTarget} $out/etc/openchami/systemd/ochami.target
  cp ${ochamiTarget} $out/lib/systemd/system/ochami.target

  # Config files (content strings with secret placeholders for envsubst)
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content:
    "cp ${pkgs.writeText name content} $out/etc/openchami/configs/${name}"
  ) configFiles)}

  # Support files (init scripts, etc.)
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (relPath: storePath:
    let dir = builtins.dirOf relPath;
    in "mkdir -p $out/etc/openchami/${dir}\ncp ${storePath} $out/etc/openchami/${relPath}"
  ) supportFiles)}

  # Secrets template
  cp ${secretsTemplate} $out/etc/openchami/secrets.env.template

  # Scripts
  cp ${activateScript} $out/bin/activate
  cp ${deactivateScript} $out/bin/deactivate
''
