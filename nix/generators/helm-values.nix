# Generate Helm values.yaml from nix/services/*.nix definitions.
#
# Usage:
#   nix build .#helm-values
#   cat result
#
{ pkgs
, lib
, defaults
, hostIP ? "192.168.100.1"
, imageOverrides ? { }
}:

let
  images = defaults.images // imageOverrides;

  # Parse image string "registry/repo:tag" into { repository, tag }.
  parseImage = img:
    let
      parts = lib.splitString ":" img;
      # Handle images with registry port (e.g. docker.io/foo:tag)
      # The last segment after ":" is the tag.
      tag = lib.last parts;
      repository = lib.concatStringsSep ":" (lib.init parts);
    in
    { inherit repository tag; };

  smdImg = parseImage images.smd;
  bssImg = parseImage images.bss;
  pcsImg = parseImage images.pcs;
  cloudInitImg = parseImage images.cloudInit;
  postgresImg = parseImage images.postgres;
  keaDhcp4Img = parseImage images.keaDhcp4;
  keaAdminImg = parseImage images.keaAdmin;
  keaSidecarImg = parseImage images.keaSidecar;
  nginxImg = parseImage images.nginx;
  tftpImg = parseImage images.tftp;
  storkImg = parseImage images.storkServer;

  values = {
    replicaCount = 1;
    pxeInterface = "virbr-pxe";
    externalIp = hostIP;

    image = {
      smd = {
        repository = smdImg.repository;
        pullPolicy = "IfNotPresent";
        tag = smdImg.tag;
      };
      postgres = {
        repository = postgresImg.repository;
        pullPolicy = "IfNotPresent";
        tag = postgresImg.tag;
      };
    };

    imagePullSecrets = [ ];
    nameOverride = "";
    fullnameOverride = "ochami";
    terminationGracePeriodSeconds = 30;

    service = {
      smd = { type = "ClusterIP"; port = defaults.ports.smd; };
      bss = { type = "ClusterIP"; port = defaults.ports.bss; };
      postgres = { type = "ClusterIP"; port = defaults.ports.postgres; };
      kea = { type = "ClusterIP"; port = 67; };
      cloudInit = { type = "ClusterIP"; port = defaults.ports.cloudInit; };
      pcs = { type = "ClusterIP"; port = defaults.ports.pcs; };
      stork = { type = "ClusterIP"; port = defaults.ports.stork; };
    };

    postgres = {
      user = defaults.databases.superuser;
      password = "";
      smd_password = "";
      bss_password = "";
      hydra_password = "";
      kea_password = "";
      pcs_password = "";
      stork_password = "";
    };

    smdInit = {
      image = {
        repository = smdImg.repository;
        tag = smdImg.tag;
        pullPolicy = "IfNotPresent";
      };
    };

    smd = {
      db = {
        host = "ochami-postgres";
        port = defaults.ports.postgres;
        name = "hmsds";
        user = "smd-user";
        opts = "sslmode=disable";
      };
      jwks.url = "";
    };

    bssInit = {
      image = {
        repository = bssImg.repository;
        tag = bssImg.tag;
        pullPolicy = "IfNotPresent";
      };
    };

    bss = {
      image = {
        repository = bssImg.repository;
        tag = bssImg.tag;
        pullPolicy = "IfNotPresent";
      };
      db = {
        host = "ochami-postgres";
        port = defaults.ports.postgres;
        name = "bssdb";
        user = "bss-user";
        opts = "sslmode=disable";
      };
      jwks.url = "";
      ipxe.server = hostIP;
      chain.proto = "http";
      bootscript.notify_url = "";
      nfdUrl = "";
      advertise_address = "localhost";
    };

    kea = {
      image = {
        repository = keaDhcp4Img.repository;
        tag = keaDhcp4Img.tag;
        pullPolicy = "IfNotPresent";
      };
      adminImage = {
        repository = keaAdminImg.repository;
        tag = keaAdminImg.tag;
        pullPolicy = "IfNotPresent";
      };
      ctrlAgent.image = {
        repository = "jonasal/kea-ctrl-agent";
        tag = "3.1.4";
        pullPolicy = "IfNotPresent";
      };
      sidecar.image = {
        repository = keaSidecarImg.repository;
        tag = keaSidecarImg.tag;
        pullPolicy = "IfNotPresent";
      };
      db = {
        host = "ochami-postgres";
        port = defaults.ports.postgres;
        name = "kea";
        user = "kea-user";
        password = "";
      };
    };

    pcsInit = {
      image = {
        repository = pcsImg.repository;
        tag = pcsImg.tag;
        pullPolicy = "IfNotPresent";
      };
    };

    pcs = {
      image = {
        repository = pcsImg.repository;
        tag = pcsImg.tag;
        pullPolicy = "IfNotPresent";
      };
      db = {
        host = "ochami-postgres";
        port = defaults.ports.postgres;
        name = "pcsdb";
        user = "pcs-user";
        opts = "sslmode=disable";
      };
    };

    serviceAccount = {
      create = true;
      annotations = { };
      name = "";
    };

    podAnnotations = { };
    podSecurityContext = { };
    securityContext = { };
    resources = { };
    nodeSelector = { };
    tolerations = [ ];
    affinity = { };

    httpServer = {
      enabled = true;
      hostNetwork = false;
      port = defaults.ports.http;
      image = {
        repository = nginxImg.repository;
        tag = nginxImg.tag;
        pullPolicy = "IfNotPresent";
      };
      service = {
        type = "NodePort";
        port = defaults.ports.http;
        nodePort = 30080;
      };
    };

    tftp = {
      enabled = true;
      hostNetwork = true;
      port = 69;
      image = {
        repository = tftpImg.repository;
        tag = tftpImg.tag;
        pullPolicy = "IfNotPresent";
      };
    };

    emulator = {
      enabled = false;
      replicas = 0;
      image = {
        repository = (defaults.images.redfishEmulator or "localhost/redfish-emulator");
        tag = "latest";
        pullPolicy = "IfNotPresent";
      };
      vmPrefix = "virtual-compute-node-";
      libvirtSocket = {
        enabled = true;
        mountPath = "/var/run/libvirt/libvirt-sock";
        hostPath = "/var/run/libvirt/libvirt-sock";
      };
    };

    cloudInit = {
      enabled = true;
      image = {
        repository = cloudInitImg.repository;
        tag = cloudInitImg.tag;
        pullPolicy = "IfNotPresent";
      };
      port = defaults.ports.cloudInit;
      clusterName = "ochami";
    };

    stork = {
      enabled = true;
      server = {
        image = {
          repository = storkImg.repository;
          tag = storkImg.tag;
          pullPolicy = "IfNotPresent";
        };
        port = defaults.ports.stork;
      };
      agent = {
        image = {
          repository = (defaults.images.storkAgent or "localhost/stork-agent");
          tag = "latest";
          pullPolicy = "IfNotPresent";
        };
        port = defaults.ports.storkAgent;
      };
      db = {
        host = "ochami-postgres";
        port = defaults.ports.postgres;
        name = "stork";
        user = "stork-user";
      };
    };
  };

  # Convert Nix attrset to YAML via JSON (nix has builtins.toJSON).
  valuesJson = builtins.toJSON values;

in
pkgs.runCommand "ochami-helm-values" {
  nativeBuildInputs = [ pkgs.yq-go ];
  passAsFile = [ "json" ];
  json = valuesJson;
} ''
  # Convert JSON to YAML for readability
  yq -P '.' "$jsonPath" > $out
''
