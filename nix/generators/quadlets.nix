# Generate podman quadlet .container files from nix/services/*.nix definitions.
#
# Usage:
#   nix build .#quadlet-units
#   ls result/
#
{ pkgs
, lib
, defaults
, hostIP ? "192.168.100.1"
, pxeInterface ? "virbr-ochami"
, dhcpRange ? "192.168.100.50 - 192.168.100.150"
, pxeCidr ? "24"
, enableStork ? false
, bootArtifacts
, imageOverrides ? { }
}:

let
  images = defaults.images // imageOverrides;
  effectiveDefaults = defaults // { inherit images; };

  # Import all service modules.
  postgres = import ../services/postgres.nix { inherit pkgs; defaults = effectiveDefaults; };
  smd = import ../services/smd.nix { defaults = effectiveDefaults; };
  bss = import ../services/bss.nix {
    inherit pkgs;
    defaults = effectiveDefaults;
    inherit hostIP bootArtifacts;
  };
  cloudInit = import ../services/cloud-init.nix { defaults = effectiveDefaults; };
  pcs = import ../services/pcs.nix { defaults = effectiveDefaults; };
  kea = import ../services/kea.nix { inherit pkgs; defaults = effectiveDefaults; inherit hostIP pxeInterface dhcpRange pxeCidr; };
  nginx = import ../services/nginx.nix {
    inherit pkgs lib;
    defaults = effectiveDefaults;
    inherit hostIP enableStork bootArtifacts;
  };
  tftp = import ../services/tftp.nix { defaults = effectiveDefaults; };

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

  # Map a volume spec to quadlet Volume= line.
  # Named volumes (ochami-*) → short name (podman manages)
  # Absolute paths → pass through
  # Config file names → /etc/openchami/configs/<name>:<rest>
  volumeToLine = v:
    let
      parts = lib.splitString ":" v;
      src = builtins.head parts;
      rest = lib.concatStringsSep ":" (builtins.tail parts);
      isNamed = lib.hasPrefix "ochami-" v;
      isAbsolute = lib.hasPrefix "/" src;
      # Strip ochami- prefix for quadlet volume names
      cleanName = builtins.replaceStrings [ "ochami-" ] [ "" ] src;
    in
    if isNamed then
      "Volume=${cleanName}:${rest}"
    else if isAbsolute then
      "Volume=${v}"
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

in
pkgs.runCommand "ochami-quadlet-units" { } ''
  mkdir -p $out
  ${lib.concatStringsSep "\n" (map (svc:
    "cp ${mkQuadletFile svc} $out/${svc.name}.container"
  ) allServices)}
  cp ${ochamiTarget} $out/openchami.target
''
