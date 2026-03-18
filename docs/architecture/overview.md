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
- `docker-compose-yml-dev` for the cutting-edge profile
- `quadlet-units` from `nix/generators/quadlets.nix`
- `quadlet-units-dev` for the cutting-edge profile
- `helm-values` from `nix/generators/helm-values.nix`
- `helm-values-dev` for the cutting-edge profile
- `deploy-profile` from `nix/deploy/profile.nix`
- `deploy-profile-dev` for the cutting-edge profile
- `boot-artifacts` from `nix/boot-artifacts.nix`
- `lab-controller-vm` from the `nix/lab/controller.nix` module
- `lab-boot-node-vm` from the `nix/lab/boot-node.nix` module

`boot-artifacts` packages the PXE/iPXE kernel, initramfs, and kernel parameters used
by the local Docker Compose and Quadlet runtime.
The lab VM outputs turn the existing NixOS smoke-lab modules into explicit VM
artifacts that can be reused as the portable Linux lab boundary.

## Runtime Layers

The unqualified flake outputs default to the `official` profile. Profile selection
changes both the enabled stack definition and the tags applied to locally built
OCI images, so generated artifacts and runtime image names stay aligned.

- `nix/images/*.nix` builds the local OCI images used for OpenCHAMI-owned services and the
  bundled Kea runtime.
- the Docker Compose and Quadlet generators default those services to the
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
See `docs/architecture/README.md` for the full architecture document and ADR index.
