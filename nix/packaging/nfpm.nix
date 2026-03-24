# Build RPM and DEB packages for OpenCHAMI podman quadlets via nfpm.
#
# Usage:
#   nix build .#packages
#   ls result/
#
# Output:
#   result/
#     openchami-quadlets-<version>-1.x86_64.rpm
#     openchami-quadlets_<version>_amd64.deb
#
{ pkgs
, lib
, quadletUnits
, version ? "0.1.0"
}:

let
  activateScript = ./activate.sh;
  deactivateScript = ./deactivate.sh;

  # Post-install: create runtime directories and reload systemd.
  postInstall = pkgs.writeText "postinstall.sh" ''
    #!/bin/sh
    mkdir -p /etc/openchami/configs
    mkdir -p /etc/openchami/artifacts
    systemctl daemon-reload || true
    echo ""
    echo "==> OpenCHAMI quadlets installed."
    echo "    1. Copy /etc/openchami/openchami.env.template to /etc/openchami/openchami.env"
    echo "    2. Fill in the secret values"
    echo "    3. Run: /usr/libexec/openchami/activate"
    echo ""
  '';

  # Pre-remove: stop services and reload.
  preRemove = pkgs.writeText "preremove.sh" ''
    #!/bin/sh
    /usr/libexec/openchami/deactivate 2>/dev/null || true
    systemctl daemon-reload || true
  '';

  # Build nfpm.yaml from the quadlet-units output.
  nfpmConfig = pkgs.writeText "nfpm.yaml" ''
    name: openchami-quadlets
    arch: amd64
    platform: linux
    version: "${version}"
    release: "1"
    maintainer: "OpenCHAMI <openchami@lanl.gov>"
    description: "OpenCHAMI bare-metal provisioning stack - podman quadlet deployment"
    vendor: "OpenCHAMI"
    homepage: "https://github.com/openchami"
    license: "MIT"

    overrides:
      rpm:
        depends:
          - podman >= 4.0
          - systemd
        recommends:
          - gettext
      deb:
        depends:
          - podman (>= 4.0)
          - systemd
        recommends:
          - gettext-base

    scripts:
      postinstall: ${postInstall}
      preremove: ${preRemove}

    contents:
      # Quadlet .container files
      - src: staging/containers/
        dst: /etc/containers/systemd/
        type: tree

      # systemd target (must be in systemd unit path, not quadlet dir)
      - src: staging/openchami.target
        dst: /etc/systemd/system/openchami.target
        type: file
        file_info:
          mode: 0644

      # Config templates (rendered at activate time)
      - src: staging/configs.templates/
        dst: /etc/openchami/configs.templates/
        type: tree

      # Postgres init scripts
      - src: staging/pg-init.templates/
        dst: /etc/openchami/pg-init.templates/
        type: tree

      # Secret env var template
      - src: staging/openchami.env.template
        dst: /etc/openchami/openchami.env.template
        type: file
        file_info:
          mode: 0644

      # Activation/deactivation scripts
      - src: staging/activate
        dst: /usr/libexec/openchami/activate
        type: file
        file_info:
          mode: 0755

      - src: staging/deactivate
        dst: /usr/libexec/openchami/deactivate
        type: file
        file_info:
          mode: 0755
  '';

in
pkgs.runCommand "openchami-packages-${version}" {
  nativeBuildInputs = [ pkgs.nfpm ];
} ''
  mkdir -p staging/containers staging/configs.templates staging/pg-init.templates

  # Copy quadlet .container files (target goes separately to systemd path)
  cp ${quadletUnits}/containers/*.container staging/containers/

  # Copy openchami.target separately (nfpm installs it to /etc/systemd/system/)
  cp ${quadletUnits}/containers/openchami.target staging/openchami.target

  # Copy config templates (with secret placeholders, not yet rendered)
  if [ -d ${quadletUnits}/configs ]; then
    cp ${quadletUnits}/configs/* staging/configs.templates/
  fi

  # Copy pg-init support files
  if [ -d ${quadletUnits}/pg-init ]; then
    cp -r ${quadletUnits}/pg-init/* staging/pg-init.templates/
  fi

  # Copy .env.template as openchami.env.template
  cp ${quadletUnits}/.env.template staging/openchami.env.template

  # Copy activate/deactivate scripts
  cp ${activateScript} staging/activate
  cp ${deactivateScript} staging/deactivate
  chmod 755 staging/activate staging/deactivate

  # Build packages
  mkdir -p $out
  nfpm package --config ${nfpmConfig} --packager rpm --target $out/
  nfpm package --config ${nfpmConfig} --packager deb --target $out/
''
