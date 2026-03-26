# Architecture Overview

## Service Images

OCI images are built from Dockerfiles in `images/<service>/Dockerfile` using
buildah or docker. Each service has its own Dockerfile that defines the build
and runtime layers.

## Deployment Artifacts

Deployment artifacts are directly maintained in `deploy/`:

- `deploy/compose/` -- Docker Compose files and config templates
- `deploy/quadlets/` -- Podman quadlet `.container` files and configs
- `deploy/helm/` -- Helm chart and values

Profile env files under `profiles/*.env` (official, dev, cscs) control image
references, registries, and version tags.

Boot artifacts (PXE/iPXE kernel, initramfs, kernel parameters) are used by the
local Docker Compose and Quadlet runtime for the selected test-node image.
The default test-node image is `almalinux`.

## Runtime Layers

The default profile is `official`. Profile selection changes the image tags and
registry references used in deployment artifacts.

- `images/<service>/Dockerfile` defines the OCI image builds for each service.
- `deploy/compose/`, `deploy/quadlets/`, and `deploy/helm/` contain the deployment
  artifacts for each method.
- `scripts/ops/` contains the operational entry points for deploy, teardown, health
  checks, boot parameter registration, node registration, and libvirt test VM setup.
- `ochami/mcp/` provides the standalone MCP server.

## Local Compose PXE Path

The validated local PXE workflow is:

1. `make deploy METHOD=compose`
2. `make create-test-vms COUNT=<n>`
3. inspect the guest console with `virsh console`

That flow uses:

- libvirt network `ochami-pxe-net`
- libvirt bridge `virbr-ochami`
- nginx and BSS config from the deploy profile
- boot artifacts mounted into the nginx container

`TEST_NODE_IMAGE` selects which test-node payload is registered with BSS and
served by nginx. Supported values are `almalinux` (default), `ubuntu`, and
`opensuse`.

See `docs/architecture/compose-pxe-lab.md` for the detailed boot path.
See `docs/architecture/README.md` for the full architecture document and ADR index.
