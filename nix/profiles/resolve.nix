{ pkgs
, lib
, defaults
, profile
}:

let
  profileName = profile.name or "unknown";

  ensureTag = service: tag:
    if builtins.match "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" tag == null then
      throw "profile ${profileName} ref for ${service} is not a valid OCI tag: ${tag}"
    else
      tag;

  normalizeDerivedTag = tag:
    builtins.replaceStrings [ "+" "/" ":" "@" " " ] [ "-" "-" "-" "-" "-" ] tag;

  keaTag = normalizeDerivedTag pkgs.kea.version;
  refs = profile.refs // { kea = keaTag; };

  localImages = {
    smd = "localhost/smd:${profile.refs.smd}";
    bss = "localhost/bss:${profile.refs.bss}";
    pcs = "localhost/pcs:${profile.refs.pcs}";
    cloudInit = "localhost/cloud-init:${profile.refs.cloudInit}";
    kea = "localhost/kea:${ensureTag "kea" refs.kea}";
    httpServer = "localhost/http-server:${profile.refs.httpServer}";
    tftp = "localhost/tftp:${profile.refs.tftp}";
    keaSync = "localhost/kea-sync:${profile.refs.keaSync}";
    redfishEmulator = "localhost/redfish-emulator:latest";
    storkAgent = "localhost/stork-agent:latest";
  };

  upstreamImages = defaults.images // {
    smd = "ghcr.io/openchami/smd:${ensureTag "smd" profile.refs.smd}";
    bss = "ghcr.io/openchami/bss:${ensureTag "bss" profile.refs.bss}";
    cloudInit = "ghcr.io/openchami/cloud-init:${ensureTag "cloudInit" profile.refs.cloudInit}";
    pcs = "ghcr.io/openchami/power-control:${ensureTag "pcs" profile.refs.pcs}";
    keaSync = "ghcr.io/openchami/kea-sync:${ensureTag "keaSync" profile.refs.keaSync}";
    tftp = "ghcr.io/openchami/tftp:${ensureTag "tftp" profile.refs.tftp}";
  };

  imageOverrides = {
    smd = localImages.smd;
    bss = localImages.bss;
    pcs = localImages.pcs;
    cloudInit = localImages.cloudInit;
    keaAdmin = localImages.kea;
    keaDhcp4 = localImages.kea;
    keaSync = localImages.keaSync;
    tftp = localImages.tftp;
    nginx = localImages.httpServer;
  };
in
profile
// {
  inherit refs localImages upstreamImages imageOverrides;
  runtimeImages = upstreamImages // imageOverrides;

  localImagePackageIds = [
    "smd"
    "bss"
    "pcs"
    "cloudInit"
    "kea"
    "httpServer"
    "tftp"
    "keaSync"
  ];
}
