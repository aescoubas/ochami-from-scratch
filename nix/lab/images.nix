# Pre-built OCI image tarballs for loading into the controller VM's podman.
#
# This module provides a script that loads upstream images into podman.
# Used by the controller VM on first boot.
#
# Note: Go service images (smd, bss, pcs, cloud-init) require real vendorHash
# values to build from source. Until those are provided, the lab uses upstream
# images from container registries directly.
{ pkgs, defaults }:

let
  # List of upstream images to pre-pull on the controller.
  upstreamImages = [
    defaults.images.postgres
    defaults.images.smd
    defaults.images.bss
    defaults.images.cloudInit
    defaults.images.pcs
    defaults.images.keaAdmin
    defaults.images.keaDhcp4
    defaults.images.keaSidecar
    defaults.images.nginx
    defaults.images.tftp
  ];

  pullScript = pkgs.writeScript "load-ochami-images.sh" ''
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Pre-pulling OpenCHAMI container images..."
    ${builtins.concatStringsSep "\n" (map (img: ''
      echo "Pulling ${img}..."
      podman pull ${img} || echo "WARNING: failed to pull ${img}"
    '') upstreamImages)}
    echo "All images loaded."
  '';
in
{
  inherit pullScript upstreamImages;
}
