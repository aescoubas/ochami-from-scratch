# Generate podman quadlet .container files from nix/services/*.nix definitions.
#
# Output:
#   result/
#     containers/       — .container quadlet units + openchami.target
#     configs/          — config files with ${VAR} secret placeholders
#     pg-init/          — postgres init scripts
#     .env.template     — lists all required secret env vars
#
# Usage:
#   nix build .#quadlet-units
#   ls result/
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
}:

let
  imageOverrides = profile.imageOverrides;
  stack = import ../services/catalog.nix {
    inherit pkgs lib;
    inherit defaults profile hostIP pxeInterface dhcpRange pxeCidr enableStork bootArtifacts;
  };

  allServices = stack.allContainerServices;
  configFiles = stack.configFiles;
  supportFiles = stack.supportFiles;

  # Map a volume spec to quadlet Volume= line.
  # Named volumes (ochami-*) → short name (podman manages)
  # Absolute paths → pass through
  # Relative paths (./) → pass through
  # Subdir paths (dir/file) → /etc/openchami/<path>:<rest>
  # Config file names (with dots) → /etc/openchami/configs/<name>:<rest>
  volumeToLine = v:
    let
      parts = lib.splitString ":" v;
      src = builtins.head parts;
      rest = lib.concatStringsSep ":" (builtins.tail parts);
      isNamed = lib.hasPrefix "ochami-" v;
      isAbsolute = lib.hasPrefix "/" src;
      isRelative = lib.hasPrefix "./" src;
      hasSlash = lib.hasInfix "/" src;
      # Strip ochami- prefix for quadlet volume names
      cleanName = builtins.replaceStrings [ "ochami-" ] [ "" ] src;
    in
    if isNamed then
      "Volume=${cleanName}:${rest}"
    else if isAbsolute then
      "Volume=${v}"
    else if isRelative then
      "Volume=/etc/openchami/${lib.removePrefix "./" src}:${rest}"
    else if hasSlash then
      "Volume=/etc/openchami/${src}:${rest}"
    else
      "Volume=/etc/openchami/configs/${src}:${rest}";

  # Generate a single .container quadlet file.
  mkQuadletFile = svc:
    let
      isOneshot = svc.type == "oneshot";
      deps = svc.after or [ ];
      afterLines = map (d: "${d}.service") deps;
      afterStr = lib.concatStringsSep " " afterLines;

      env = svc.environment or { };
      envLines = lib.mapAttrsToList (k: v: "Environment=${k}=${v}") env;
      envMappingLines = lib.mapAttrsToList
        (containerVar: _secretVar: "Environment=${containerVar}=\${${containerVar}}")
        (svc.envMapping or { });

      volumes = svc.volumes or [ ];
      volumeLines = map volumeToLine volumes;

      caps = svc.capabilities or [ ];
      capLines = map (c: "AddCapability=${c}") caps;

      command = svc.command or "";
      execLine = lib.optional (command != "") "Exec=${command}";

      healthLines =
        if svc ? healthCheck then [
          "HealthCmd=${svc.healthCheck}"
          "HealthInterval=5s"
          "HealthTimeout=5s"
          "HealthRetries=30"
        ]
        else [ ];

      notifyLine = lib.optional (svc ? healthCheck && !isOneshot) "Notify=healthy";

      unitSection = lib.concatStringsSep "\n" (lib.filter (s: s != "") [
        "[Unit]"
        "Description=OpenCHAMI ${svc.name}"
        (lib.optionalString (afterStr != "") "After=${afterStr}")
        (lib.optionalString (afterStr != "") "Requires=${afterStr}")
      ]);

      containerSection = lib.concatStringsSep "\n" (lib.filter (s: s != "") ([
        "[Container]"
        "Image=${svc.image}"
        "Network=host"
      ]
      ++ envLines
      ++ envMappingLines
      ++ [ "EnvironmentFile=/etc/openchami/openchami.env" ]
      ++ volumeLines
      ++ execLine
      ++ capLines
      ++ healthLines
      ++ notifyLine));

      serviceSection = lib.concatStringsSep "\n" [
        "[Service]"
        "Restart=${if isOneshot then "no" else "on-failure"}"
        "TimeoutStartSec=${if isOneshot then "120" else "300"}"
      ];

      installSection = lib.concatStringsSep "\n" [
        "[Install]"
        "WantedBy=openchami.target"
      ];

      content = lib.concatStringsSep "\n\n" [
        unitSection
        containerSection
        serviceSection
        installSection
      ] + "\n";
    in
    pkgs.writeText "${svc.name}.container" content;

  # The openchami.target unit.
  ochamiTarget = pkgs.writeText "openchami.target" ''
    [Unit]
    Description=OpenCHAMI Services
    Wants=${lib.concatStringsSep " " (map (s: "${s.name}.service") allServices)}

    [Install]
    WantedBy=multi-user.target
  '';

  # .env.template: list all required secret env vars.
  envTemplate = lib.concatStringsSep "\n" (map (k: "${k}=") defaults.secretKeys) + "\n";

in
pkgs.runCommand "ochami-quadlet-units" { } ''
  mkdir -p $out/containers $out/configs $out/pg-init

  # Quadlet .container units
  ${lib.concatStringsSep "\n" (map (svc:
    "cp ${mkQuadletFile svc} $out/containers/${svc.name}.container"
  ) allServices)}
  cp ${ochamiTarget} $out/containers/openchami.target

  # Config files (content strings → files)
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: content:
    "cp ${pkgs.writeText name content} $out/configs/${name}"
  ) configFiles)}

  # Support files (Nix store paths → relative locations)
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (relPath: storePath:
    let dir = builtins.dirOf relPath;
    in "mkdir -p $out/${dir}\ncp ${storePath} $out/${relPath}"
  ) supportFiles)}

  # .env.template
  cp ${pkgs.writeText "env.template" envTemplate} $out/.env.template
''
