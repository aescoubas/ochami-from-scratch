# Architecture Overview

## Source Of Truth

`nix/services/*.nix` defines the OpenCHAMI services. Those definitions control:

- image references
- ports
- environment variables
- volumes
- health checks
- service dependencies

Generated deployment artifacts must follow those service definitions. They are not
hand-written.

## Generated Artifacts

The repository currently exports these Nix-built artifacts:

- `docker-compose-yml` from `nix/generators/docker-compose.nix`
- `quadlet-units` from `nix/generators/quadlets.nix`
- `helm-values` from `nix/generators/helm-values.nix`
- `deploy-profile` from `nix/deploy/profile.nix`
- `boot-artifacts` from `nix/boot-artifacts.nix`

`boot-artifacts` packages the PXE/iPXE kernel, initramfs, and kernel parameters used
by the local Docker Compose and Quadlet runtime.

## Runtime Layers

- `nix/images/*.nix` builds the local OCI images used for OpenCHAMI-owned services.
- the Docker Compose and Quadlet generators default OpenCHAMI-owned services to those
  locally built `localhost/*` images
- `scripts/ops/` contains the operational entry points for deploy, teardown, health
  checks, boot parameter registration, node registration, and libvirt test VM setup.
- `ochami-helm/` contains the Helm chart that consumes generated values for Minikube.
- `ochami/mcp/` provides the standalone MCP server.

## Local Compose PXE Path

The validated local PXE workflow is:

1. `make deploy METHOD=compose`
2. `make create-test-vms COUNT=<n>`
3. inspect the guest console with `virsh console`

That flow uses:

- libvirt network `ochami-pxe-net`
- libvirt bridge `virbr-ochami`
- generated nginx and BSS config from the Nix deploy profile
- generated boot artifacts mounted into the nginx container

See `docs/architecture/compose-pxe-lab.md` for the detailed boot path.
