# Controller VM Lab Portability Plan

Date: 2026-03-17
Status: Completed for the controller-VM deploy path and the Linux libvirt-backed compute-node PXE flow
Owner: Codex / OpenCHAMI from Scratch

## Context

The current validated local workflow is a Linux-host-native Docker Compose plus
libvirt PXE lab. That path assumes:

- Linux host networking via `network_mode: host`
- Linux bridge management (`ip link`, dummy carrier interfaces)
- system libvirt network control from the host
- host-visible DHCP/TFTP traffic for compute-node PXE boot

Those assumptions work on Ubuntu but do not translate cleanly to macOS, even
when Homebrew provides compatibility shims for `ip` and `ss`. The repository
already contains the seed of a more portable lab under `nix/lab/` and
`nix/tests/lab-smoke.nix`, but it is currently only a smoke-test artifact and
not a first-class workflow.

## Decision

Adopt a Linux controller VM as the portability boundary for the OpenCHAMI lab.

The controller VM will host the OpenCHAMI control plane and the PXE-facing
services inside a Linux guest. Host platforms such as Ubuntu and macOS will
only be responsible for building, launching, and managing the controller VM,
not for reproducing Linux bridge and PXE host behavior directly.

## Goals

1. Preserve the current fast Ubuntu host-native compose/libvirt flow.
2. Establish a controller-VM path that can become the cross-platform default lab.
3. Allow macOS to drive the same Linux lab boundary over SSH or a local VM
   instead of attempting native Darwin PXE/libvirt parity.
4. Reuse the existing `nix/lab/` modules instead of creating a second lab stack.

## Non-goals

- Native macOS DHCP/TFTP/libvirt bridge parity.
- Replacing the current Ubuntu compose path immediately.
- Solving Apple Silicon nested x86 virtualization performance in the first slice.

## Target Architecture

- Host:
  - provides Nix, QEMU/VM runtime, and SSH access
  - launches or connects to the controller VM
- Controller VM:
  - runs Linux
  - hosts OpenCHAMI services, boot artifacts, and PXE-facing networking
  - becomes the only place that needs Linux bridge/libvirt semantics
- Compute VMs:
  - either run under the same Linux lab boundary or are attached to it from a
    Linux-capable backend

## Phases

### Phase 1: Formalize the controller VM path

- Add a dated plan document and roadmap entry.
- Export explicit flake outputs for controller and boot-node VM artifacts based
  on the existing `nix/lab/` modules.
- Add Makefile targets and README entries so the path is visible and usable.

Acceptance:

- `nix build .#lab-controller-vm` works on Linux.
- `nix build .#lab-boot-node-vm` works on Linux.
- The README documents the controller-VM path and positions it as the portable
  direction for macOS.

### Phase 2: Separate host-native deploy from lab orchestration

- Split generic control-plane deploy from PXE/lab preparation in
  `scripts/ops/deploy.sh`.
- Move libvirt bridge/network setup behind a lab-specific backend instead of
  forcing it during every compose deploy.
- Keep the current Ubuntu path as the optimized `linux-pxe` backend.

Acceptance:

- Ubuntu `make deploy METHOD=compose` keeps the existing behavior.
- A controller-VM-oriented path exists that does not require Darwin hosts to
  expose Linux networking features directly.

### Phase 3: Add a host-facing lab backend

- Introduce a lab backend command or target such as `make build-lab-controller-vm`
  and eventually `make deploy METHOD=lab-vm`.
- Allow the host to launch or connect to the controller VM over SSH.
- Route lab-only actions such as compute-VM creation through the controller
  backend instead of the host OS.

Acceptance:

- macOS can drive the controller VM path without requiring native host PXE
  bridge setup.
- Ubuntu can opt into the same controller-VM path for reproducible isolation.

### Phase 4: Make compute-node orchestration backend-aware

- Move compute-node boot orchestration behind a backend abstraction.
- Support at least:
  - `linux-host-libvirt`
  - `controller-vm`
- Keep `create-test-vms.sh` functional on Ubuntu while making the controller VM
  the portable path.

Acceptance:

- The host OS no longer needs to create PXE test VMs directly in the portable
  workflow.

### Phase 5: Promote the controller VM path to the preferred portable workflow

- Update the README support matrix.
- Document Ubuntu fast path versus controller-VM portable path.
- Add verification guidance for Ubuntu and macOS.

Acceptance:

- Ubuntu fast path remains documented and supported.
- macOS has a first-class documented workflow that uses the controller VM
  instead of pretending to be a Linux PXE host.

## Risks

- Apple Silicon may require slower emulated x86 guests for some compute-node
  scenarios.
- Nested virtualization may not be viable for all host/hypervisor combinations.
- Some current smoke-lab artifacts are placeholders and must be upgraded toward
  real OpenCHAMI service wiring.

## Verification Strategy

Required repository verification remains:

- `make test`
- `nix build .#docker-compose-yml`
- `nix build .#quadlet-units`
- `nix build .#deploy-profile`

Additional controller-VM verification for this effort:

- `nix build .#lab-controller-vm`
- `nix build .#lab-boot-node-vm`

## Implemented Slice

This turn implemented Phases 1 through 3 for the controller-VM deploy path:

- wrote this plan and registered the work in `docs/plans/ROADMAP.md`
- exported controller and boot-node guest system closures plus standalone VM artifacts from the flake
- added Makefile and README entry points for the new lab VM artifacts
- added `make deploy METHOD=lab-vm` / `make teardown METHOD=lab-vm`
- switched the Linux `lab-vm` backend from a direct QEMU process to a libvirt-defined controller domain
- added macOS support for `lab-vm` by warming the Linux guest closure from a Linux build host when a native `x86_64-linux` builder is unavailable
- added tests to lock the new outputs and script behavior into the repo structure

## Implemented Follow-up

This follow-up turn completed the first Linux `controller-vm` compute-node flow:

- exposed the controller guest's BSS, Kea control, and SMD ports on localhost for host-side orchestration and health checks
- made the controller guest's `kea-init` database bootstrap idempotent so controller restarts preserve a working PXE stack
- extended `create-test-vms.sh` and `make create-test-vms` with `METHOD=lab-vm`
- verified a live Linux compute VM can receive DHCP from the controller guest, fetch the iPXE bootscript, and download the kernel/initramfs from the guest-hosted HTTP service
