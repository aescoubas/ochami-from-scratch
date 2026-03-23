# Test Node Images Plan

Status: Completed

Date: 2026-03-19

## Goal

Support these selectable test-node boot images in the local PXE workflows:

- `almalinux`
- `opensuse`
- `ubuntu`
- `nixos`

The primary target is one selected image per deploy/bootstrap run. Mixed-image
per-node labs can be added later without reworking the core model.

## Current Constraints

- `nix/boot-artifacts.nix` currently produces a single NixOS netboot payload.
- Multiple runtime paths still assume one hardcoded artifact directory and one
  NixOS-flavoured console-ready pattern.
- The compose and controller-VM flows already share the same boot-artifact and
  BSS default-registration concepts, so image selection should stay centralized.

## Scope

### Included

- Add a Nix boot-image catalog with pinned sources and metadata for all four
  supported images.
- Export per-image boot-artifact flake outputs.
- Thread a selected image through deploy, health-check, BSS default registration,
  and `create-test-vms`.
- Keep the generated nginx and deploy-profile paths aligned with the selected
  image.
- Update docs and regression tests.

### Deferred

- Per-node `boot_image` overrides in `nodes.csv`.
- Shipping large local Ubuntu ISO payloads from nginx. The initial Ubuntu path
  may reference the official live-server ISO URL from Canonical.
- Live matrix validation for every image on every host OS in one change.

## Design

### 1. Boot image catalog

Add a catalog that defines, per image:

- `id`
- `label`
- `kernelFile`
- `initrdFile`
- `relativeDir`
- `kernelArgs`
- `consoleReadyPattern`
- pinned upstream source URLs and hashes

The selected image becomes the single source of truth for boot-artifact layout,
BSS defaults, static `boot.ipxe`, and console readiness checks.

### 2. Artifact production

- `nixos`: keep the existing locally built NixOS netboot path.
- `ubuntu`: fetch Canonical's amd64 netboot tarball, extract `linux` and
  `initrd`, and use the official live-server ISO URL in the kernel parameters.
- `opensuse`: fetch the Leap installer `linux` and `initrd` artifacts from the
  official repository and use the Leap OSS install repository in kernel params.
- `almalinux`: fetch the BaseOS PXE `vmlinuz` and `initrd.img` artifacts from
  the official repository and use standard Anaconda repository parameters.

### 3. Selection plumbing

Expose `TEST_NODE_IMAGE` end to end:

- `Makefile`
- `scripts/ops/deploy.sh`
- `scripts/ops/register-bss-defaults.sh`
- `scripts/ops/health-check.sh`
- `scripts/ops/create-test-vms.sh`
- `scripts/ops/lab-vm.sh`
- `flake.nix`

Default to `nixos`.

### 4. Verification

Regression tests should cover:

- flake exports for per-image boot artifacts
- the Makefile and operational scripts exposing `TEST_NODE_IMAGE`
- boot-artifact metadata for all four images
- removal of hardcoded `artifacts/opensuse` assumptions from runtime scripts

Build verification:

- `make test`
- `nix build .#boot-artifacts-nixos`
- `nix build .#boot-artifacts-ubuntu`
- `nix build .#boot-artifacts-opensuse`
- `nix build .#boot-artifacts-almalinux`
- `nix build .#docker-compose-yml`
- `nix build .#quadlet-units`
- `nix build .#deploy-profile`

## Rollout Order

1. Add tests and the boot-image catalog.
2. Rework `boot-artifacts.nix` around the selected image.
3. Thread `TEST_NODE_IMAGE` through deploy/runtime scripts.
4. Update docs and verify builds.

## Risks

- Ubuntu's installer still depends on reaching the referenced ISO URL unless a
  later change stages the ISO locally.
- Serial-console readiness strings may differ across installers; the initial
  regexes should be treated as pragmatic defaults and refined with live boots.
