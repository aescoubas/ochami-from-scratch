# Compose Local Image Runtime Fixes Plan

Date: 2026-03-13

## Problem

The current `make deploy METHOD=compose` path is broken in two layers:

1. The checked-in `ochami-docker-compose/docker-compose.yml` is stale and still points at upstream `ghcr.io/openchami/*` images, so the default deploy path bypasses the generated Nix artifact.
2. The generated local-image path still fails at runtime because several service commands and image layouts do not match the binaries, assets, and user/group data present in the locally built images.

## Goals

- Remove the stale checked-in compose artifact from the default path.
- Make Docker Compose deploy/teardown use a managed generated compose file consistently.
- Align service command paths with the binaries exported by the Nix-built images.
- Package the runtime assets needed by the PCS, nginx, and tftp images.
- Verify the end-to-end compose flow locally.

## Workstreams

### 1. Artifact Selection

- Delete the checked-in `ochami-docker-compose/docker-compose.yml`.
- Update `scripts/ops/deploy.sh` to always regenerate a managed compose file before `docker compose up`.
- Update `scripts/ops/teardown.sh` to target the same managed compose file by default.
- Keep compose-relative config mounts working by generating the file into `ochami-docker-compose/`.

### 2. Service Command Parity

- Fix `nix/services/smd.nix` to run `/bin/smd-init`.
- Fix `nix/services/bss.nix` to run `/bin/bss-init`.
- Fix `nix/services/cloud-init.nix` to run `/bin/cloud-init-server`.

### 3. Runtime Image Parity

- Update `nix/images/pcs.nix` to include the upstream `migrations/` tree and set a working directory that matches the binary’s default `./migrations/postgres` lookup.
- Update `nix/images/http-server.nix` to provide the `nobody` user/group expected by nginx.
- Update `nix/images/tftp.nix` to provide the `nobody` user/group and ownership required by `in.tftpd`.

### 4. Regression Coverage

- Add tests for the managed compose-file behavior in the deploy/teardown scripts.
- Add tests for the corrected service command paths.
- Add tests for the PCS migration packaging and nginx/tftp NSS setup.

## Verification

- `make test`
- `nix build .#docker-compose-yml`
- `nix build .#quadlet-units`
- `nix build .#deploy-profile`
- `make deploy METHOD=compose`
- `make teardown METHOD=compose`
