{ pkgs
, lib
, defaults
, profile
, hostIP ? "192.168.100.1"
, pxeInterface ? "virbr-ochami"
, dhcpRange ? "192.168.100.50 - 192.168.100.150"
, pxeCidr ? "24"
, bootArtifacts
, enableStork ? false
}:

let
  effectiveDefaults = defaults // {
    images = profile.runtimeImages;
  };

  postgres = import ../services/postgres.nix { inherit pkgs; defaults = effectiveDefaults; };
  smd = import ../services/smd.nix { defaults = effectiveDefaults; };
  bss = import ../services/bss.nix {
    inherit pkgs;
    defaults = effectiveDefaults;
    inherit hostIP bootArtifacts;
  };
  cloudInit = import ../services/cloud-init.nix { defaults = effectiveDefaults; };
  pcs = import ../services/pcs.nix { defaults = effectiveDefaults; };
  kea = import ../services/kea.nix {
    inherit pkgs;
    defaults = effectiveDefaults;
    inherit hostIP pxeInterface dhcpRange pxeCidr;
  };
  nginx = import ../services/nginx.nix {
    inherit pkgs lib;
    defaults = effectiveDefaults;
    inherit hostIP enableStork bootArtifacts;
  };
  tftp = import ../services/tftp.nix { defaults = effectiveDefaults; };

  containerServices = {
    postgres = postgres.service;
    "smd-init" = smd.init;
    smd = smd.service;
    "bss-init" = bss.init;
    bss = bss.service;
    "cloud-init" = cloudInit.service;
    "pcs-init" = pcs.init;
    pcs = pcs.service;
    "kea-init" = kea.init;
    kea = kea.service;
    "kea-sync" = kea.sync;
    "http-server" = nginx.service;
    tftp = tftp.service;
  };

  scriptServices = {
    "bss-boot-defaults" = bss.bootDefaults;
  };

  selectServices = ids: available:
    map (id:
      available.${id} or (throw "unknown service id '${id}' in profile ${profile.name}")
    ) ids;

  profileEnablesAny = ids:
    lib.any (id: lib.elem id profile.containerServiceIds) ids;

  configFiles =
    (if profileEnablesAny [ "kea-init" "kea" "kea-sync" ] then kea.configFiles else { })
    // (if profileEnablesAny [ "http-server" ] then nginx.configFiles else { });
in
{
  inherit effectiveDefaults containerServices scriptServices configFiles;
  allContainerServices = selectServices profile.containerServiceIds containerServices;
  allScriptServices = selectServices (profile.scriptServiceIds or [ ]) scriptServices;
}
