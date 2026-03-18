# Generate docker-compose.yml from nix/services/*.nix definitions.
#
# Usage:
#   nix build .#docker-compose-yml
#   cat result
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

  # --- YAML helpers ---

  indent = n: s:
    let pad = lib.concatStrings (lib.genList (_: " ") n);
    in lib.concatStringsSep "\n" (
      map (line: if line == "" then "" else "${pad}${line}")
        (lib.splitString "\n" s)
    );

  # Build the depends_on block for a service.
  # Oneshot services get service_completed_successfully, others get service_healthy.
  mkDependsOn = svc:
    let
      deps = svc.after or [ ];
      # Map service name back to its definition to check type.
      svcLookup = builtins.listToAttrs (map (s: { name = s.name; value = s; }) allServiceDefs);
      conditionFor = depName:
        let dep = svcLookup.${depName} or null;
        in if dep != null && dep.type == "oneshot" then "service_completed_successfully"
        else "service_healthy";
    in
    if deps == [ ] then ""
    else
      "depends_on:\n" +
      lib.concatStringsSep "\n" (map
        (d: "  ${d}:\n    condition: ${conditionFor d}")
        deps);

  # Build environment block.
  mkEnvironment = svc:
    let
      # secretEnvKeys: pass-through vars with same name (e.g. SMD_DB_PASSWORD → SMD_DB_PASSWORD)
      secretPassthrough = builtins.listToAttrs (map
        (k: { name = k; value = "\${${k}:?${k} is required}"; })
        (svc.secretEnvKeys or [ ]));
      # envMapping: rename vars (e.g. SMD_DBPASS → SMD_DB_PASSWORD)
      mappedSecrets = lib.mapAttrs
        (_containerVar: secretVar:
          "\${${secretVar}:?${secretVar} is required}")
        (svc.envMapping or { });
      env = (svc.environment or { }) // secretPassthrough // mappedSecrets;
    in
    if env == { } then ""
    else
      "environment:\n" +
      lib.concatStringsSep "\n" (lib.mapAttrsToList
        (k: v: "  ${k}: ${builtins.toJSON v}")
        env);

  # Map a volume source: config file names become ./configs/<name> paths.
  mapVolSrc = v:
    let
      parts = lib.splitString ":" v;
      src = builtins.head parts;
      rest = lib.concatStringsSep ":" (builtins.tail parts);
      isPath = lib.hasPrefix "/" src;
      isOchami = lib.hasPrefix "ochami-" src;
      isConfigFile = lib.hasInfix "." src && !isPath && !isOchami;
    in
    if isConfigFile then "./configs/${src}:${rest}"
    else v;

  # Build volumes block.
  mkVolumes = svc:
    let vols = svc.volumes or [ ];
    in
    if vols == [ ] then ""
    else
      "volumes:\n" +
      lib.concatStringsSep "\n" (map (v: "  - ${mapVolSrc v}") vols);

  # Build healthcheck block.
  mkHealthcheck = svc:
    if !(svc ? healthCheck) then ""
    else ''
      healthcheck:
        test: ["CMD-SHELL", "${svc.healthCheck}"]
        interval: 5s
        timeout: 5s
        retries: 30'';

  # Build capabilities block.
  mkCapAdd = svc:
    let caps = svc.capabilities or [ ];
    in
    if caps == [ ] then ""
    else
      "cap_add:\n" +
      lib.concatStringsSep "\n" (map (c: "  - ${c}") caps);

  # Build command block.
  mkCommand = svc:
    let cmd = svc.command or "";
    in
    if cmd == "" then ""
    else "command: [${lib.concatStringsSep ", " (map builtins.toJSON (lib.splitString " " cmd))}]";

  # Assemble a single compose service entry.
  mkComposeService = svc:
    let
      isOneshot = svc.type == "oneshot";
      blocks = lib.filter (s: s != "") [
        "image: ${svc.image}"
        "network_mode: host"
        (mkDependsOn svc)
        (mkEnvironment svc)
        (mkCommand svc)
        (mkVolumes svc)
        (mkCapAdd svc)
        (mkHealthcheck svc)
        (lib.optionalString isOneshot ''restart: "no"'')
      ];
    in
    "  ${svc.name}:\n" +
    indent 4 (lib.concatStringsSep "\n" blocks);

  # All service definitions (flat list for dependency lookup).
  allServiceDefs = stack.allContainerServices;

  # Ordered service entries for the compose file.
  composeServices = lib.concatStringsSep "\n\n" (map mkComposeService allServiceDefs);

  # Named volumes referenced in service definitions.
  namedVolumes =
    let
      allVols = lib.concatMap (s: s.volumes or [ ]) allServiceDefs;
      isNamed = v: lib.hasPrefix "ochami-" v;
      extractName = v: builtins.head (lib.splitString ":" v);
      # Keep named volumes centralized from the service definitions.
      names = lib.unique (map extractName (lib.filter isNamed allVols));
    in
    names;

  # Also find non-ochami named volumes (like standalone names that aren't paths).
  simpleNamedVolumes =
    let
      allVols = lib.concatMap (s: s.volumes or [ ]) allServiceDefs;
      extractSrc = v: builtins.head (lib.splitString ":" v);
      isPath = s: lib.hasPrefix "/" s;
      isOchami = s: lib.hasPrefix "ochami-" s;
      # A named volume is one that doesn't start with / and isn't a config file name with dots
      isNamedVol = v:
        let src = extractSrc v;
        in !isPath src && !isOchami src && !lib.hasInfix "." src;
    in
    lib.unique (map extractSrc (lib.filter isNamedVol allVols));

  volumeNames = namedVolumes ++ simpleNamedVolumes;

  volumesBlock =
    if volumeNames == [ ] then ""
    else
      "\nvolumes:\n" +
      lib.concatStringsSep "\n" (map (v: "  ${v}:") volumeNames);

  composeYaml = ''
    services:
    ${composeServices}
    ${volumesBlock}
  '';

in
pkgs.writeText "docker-compose.yml" composeYaml
