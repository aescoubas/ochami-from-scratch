# OpenCHAMI From Scratch

This repository packages a local OpenCHAMI control plane around:

- Nix-defined service metadata in `nix/services/*.nix`
- Nix-generated deployment artifacts in `nix/generators/*.nix`
- Nix-built OCI images in `nix/images/*.nix`
- Bash operational entry points in `scripts/ops/`

The validated end-to-end local workflow is Docker Compose plus libvirt PXE boot:

1. deploy the stack with `make deploy METHOD=compose`
2. create a libvirt VM with `make create-test-vms COUNT=1`
3. confirm the guest reaches the `ochami-netboot` serial console

There is no Python deployment CLI in this repository. The only Python application
entry point is the standalone MCP server in `ochami/mcp/`.

## What Is Generated

`nix/services/*.nix` is the single source of truth for service definitions:

- image references
- ports
- environment variables
- volumes
- dependencies
- health checks

Those definitions drive the generated deployment artifacts:

- `nix build .#docker-compose-yml`
- `nix build .#quadlet-units`
- `nix build .#helm-values`
- `nix build .#deploy-profile`
- `nix build .#boot-artifacts`
- `nix build .#lab-controller-vm`
- `nix build .#lab-boot-node-vm`

The runtime files under `ochami-docker-compose/` and `ochami-quadlets/` are
generated outputs and rendered configs. They are not hand-maintained source files.

## Prerequisites

Most deployment-oriented functionality is Linux-only.

For the validated Docker Compose PXE path, the host needs:

- `nix`
- `docker` plus `docker compose`
- `virsh`, `virt-install`, and `qemu-img`
- `curl`, `jq`, `envsubst`, `ss`, `ip`, and `timeout`
- passwordless `sudo` for libvirt network and bridge preparation

Check the compose prerequisites with:

```bash
make check METHOD=compose
sudo -n true
```

`nix develop` is useful for Python/package work, but it does not replace the host
requirements above. In particular, Docker, libvirt, and `envsubst` are expected to
exist on the host.

The operational scripts export `NIX_CONFIG=experimental-features = nix-command flakes`
and use `path:` flake references automatically, so they work from a live working
tree even when flakes are not enabled in the host's persistent Nix config.

### macOS bootstrap

macOS can cover the local development and generation workflow, and it is the
target host for the controller-VM path described below. The validated host-native
PXE/libvirt deployment path above is still Linux-only. If you want to work from
macOS anyway, install the toolchain with:

```bash
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon
brew install jq gettext coreutils iproute2mac qemu libvirt virt-manager
brew install --cask docker-desktop
```

`envsubst` comes from Homebrew `gettext`, and `timeout` comes from Homebrew
`coreutils`. Add both to your shell `PATH`:

```bash
echo 'export PATH="$(brew --prefix gettext)/bin:$(brew --prefix coreutils)/libexec/gnubin:$PATH"' >> ~/.zprofile
source ~/.zprofile
```

The operational scripts also prepend the common Homebrew and Nix locations on
Darwin, so non-interactive shells such as `ssh macbook 'make ...'` can
find `nix`, `envsubst`, `ip`, `ss`, and `timeout` without relying on shell rc
files.

After Docker Desktop finishes installing, start it once so the Docker daemon and
`docker compose` are available in your shell.

On macOS, the current split is:

- use `nix build`, `nix develop`, and `make test` natively
- use `make deploy METHOD=lab-vm` plus `make create-test-vms METHOD=lab-vm COUNT=1` for the portable controller-plus-compute VM workflow
- keep `make deploy METHOD=compose` for Linux hosts only

On Linux, `lab-vm` defines and starts the controller through libvirt on
`qemu:///system` by default, so it is visible with:

```bash
virsh --connect qemu:///system list
```

On macOS, `lab-vm` now uses libvirt session domains on `qemu:///session`.
Both `openchami-controller` and `ochami-test-node-*` appear in `virsh list`,
and the macOS compute path still uses the controller VM's BSS-generated kernel,
initrd, and kernel arguments over user networking instead of relying on raw PXE
broadcasts between guests:

```bash
virsh list
virsh console openchami-controller
virsh console ochami-test-node-0
```

Even with Homebrew `iproute2mac`, the operational scripts still rely on Linux
bridge and libvirt network behavior that macOS does not provide directly.
`make check METHOD=compose` intentionally fails on macOS unless you opt into the
unsupported path with `OPENCHAMI_ALLOW_UNSUPPORTED_DARWIN=1`.

## Quick Start

### From Scratch: Docker Compose PXE

Start from the repository root.

Check prerequisites:

```bash
make check METHOD=compose
```

If you want a clean compose state first:

```bash
make teardown METHOD=compose
```

This is recommended after interrupted or failed compose runs, because stale compose
volumes can preserve Postgres and Kea state.

Deploy the stack:

```bash
make deploy METHOD=compose
```

This compose path:

- ensures the secrets file exists at `.tmp/openchami-secrets.env`
- builds and loads local OCI images for OpenCHAMI services plus the bundled Kea runtime
- generates `ochami-docker-compose/docker-compose.generated.yml`
- builds `.#deploy-profile` and renders runtime configs into `ochami-docker-compose/configs/`
- ensures the libvirt PXE network `ochami-pxe-net` exists on bridge `virbr-ochami`
- temporarily pauses conflicting libvirt DHCP networks while PXE is active
- registers default BSS boot parameters from `.#boot-artifacts`

Create and register a test VM:

```bash
make create-test-vms COUNT=1
```

If existing `ochami-test-node-*` domains are already defined, use a fresh index:

```bash
scripts/ops/create-test-vms.sh --count 1 --start-index 2
```

Inspect the guest console:

```bash
sudo virsh --connect qemu:///system console ochami-test-node-0
```

Inside the guest, verify the OpenCHAMI-provided kernel args:

```bash
cat /proc/cmdline
```

The successful path is:

- the console reaches the `ochami-netboot` login
- `/proc/cmdline` includes values such as `xname=...`, `nid=...`,
  `bss_referral_token=...`, and `ds=nocloud-net;s=192.168.100.1/`

Exit the serial console with `Ctrl+]`.

### Teardown

Tear down the compose deployment with:

```bash
make teardown METHOD=compose
```

That removes the compose containers and volumes, removes the temporary PXE bridge
carrier helper if one was attached, and restores any libvirt DHCP networks paused
during deploy.

It does not remove libvirt test VMs or their qcow2 disks.

To remove a test VM manually:

```bash
sudo virsh --connect qemu:///system destroy ochami-test-node-0 || true
sudo virsh --connect qemu:///system undefine ochami-test-node-0
sudo rm -f /var/lib/libvirt/images/ochami/ochami-test-node-0.qcow2
```

### Controller VM Lab

Build and run the portable controller VM with:

```bash
make deploy METHOD=lab-vm
```

On Linux, that path builds the controller guest from the NixOS lab modules,
defines `openchami-controller` through libvirt on `qemu:///system`, starts the
domain, and forwards these host ports by default:

- `127.0.0.1:28000` to the guest HTTP server for `boot.ipxe`
- `127.0.0.1:10022` to the guest SSH service
- `127.0.0.1:29778` to the guest BSS API
- `127.0.0.1:28800` to the guest Kea control socket
- `127.0.0.1:29779` to the guest SMD API

Inspect the running controller domain with:

```bash
virsh --connect qemu:///system list
virsh --connect qemu:///system dominfo openchami-controller
virsh console openchami-controller
```

On macOS, the same command defines `openchami-controller` through the libvirt
session daemon on `qemu:///session`, using the Nix-built x86_64 QEMU binary and
SLIRP host-forwards for the controller endpoints:

```bash
virsh list
virsh dominfo openchami-controller
virsh console openchami-controller
```

The deploy health check waits for:

```bash
curl -fsS http://127.0.0.1:28000/boot.ipxe
```

Stop the controller VM with:

```bash
make teardown METHOD=lab-vm
```

On Linux, you can also attach libvirt compute VMs to the controller's isolated
PXE network and boot them from the controller guest:

```bash
make create-test-vms METHOD=lab-vm COUNT=1
virsh --connect qemu:///system console ochami-test-node-0
```

That path reuses the `openchami-lab-net` libvirt network, registers the node
against the controller guest's SMD API through the forwarded localhost port,
and waits for the controller-hosted BSS bootscript before starting the VM.

On macOS, the same command defines a libvirt session domain that boots from the
controller VM's BSS-generated kernel, initrd, and kernel arguments over user
networking:

```bash
make create-test-vms METHOD=lab-vm COUNT=1
virsh list
virsh console ochami-test-node-0
```

The expected success path is the same: the console reaches `ochami-netboot`,
and `/proc/cmdline` inside the guest shows the controller-generated `xname`,
`nid`, `bss_referral_token`, and `ds=nocloud-net;s=http://10.0.2.2:28000/cloud-init/`
arguments. The translated iPXE script and extracted kernel arguments are cached
under `.tmp/lab-vm/compute/boot/<domain>/` for inspection, and the captured
serial transcript is written to `.tmp/lab-vm/compute/logs/ochami-test-node-0.serial.log`.

Relevant overrides:

- `LAB_VM_CONTROLLER_HTTP_PORT`
- `LAB_VM_CONTROLLER_SSH_PORT`
- `LAB_VM_CONTROLLER_BSS_PORT`
- `LAB_VM_CONTROLLER_KEA_CTRL_PORT`
- `LAB_VM_CONTROLLER_SMD_PORT`
- `LAB_VM_STATE_DIR`
- `LAB_VM_LIBVIRT_URI`
- `LAB_VM_CONTROLLER_DOMAIN`
- `OPENCHAMI_LAB_VM_BUILD_HOST`
- `OPENCHAMI_LAB_VM_BUILD_REPO_PATH`
- `OPENCHAMI_LAB_VM_BUILD_SSH_OPTS`

On Linux, the default `LAB_VM_STATE_DIR` is `~/.local/state/openchami/lab-vm`
so libvirt-owned state files stay out of the git worktree. On non-Linux hosts,
the default remains `.tmp/lab-vm` under the repository root.

On macOS, expect the first `lab-vm` deploy to pull a large Linux guest closure into
the local Nix store before the VM can boot. After that initial cache warm-up, repeat
deploys are much faster.

If that realization cannot be satisfied entirely from binary caches, the macOS host
needs either an `x86_64-linux` Nix builder or a Linux build host for this repo.
Set `OPENCHAMI_LAB_VM_BUILD_HOST=user@linux-host` and, if needed,
`OPENCHAMI_LAB_VM_BUILD_REPO_PATH=/path/to/ochami-from-scratch` so the Mac can warm
the Linux guest closure from that machine before defining the local libvirt session
domains. When using that fallback on macOS, passwordless `sudo` is also required so the
local Nix store can import the remote closure as a trusted user. Without one of those
Linux-backed paths, `make deploy METHOD=lab-vm` can fail during the Linux guest build
even though the local VM lifecycle is libvirt-managed.

## Secrets And Config Rendering

The compose and quadlet flows use two layers of generation:

1. Nix generates the deployment artifacts and config templates.
2. The operational scripts render runtime config files with secrets from a secrets
   file via `envsubst`.

That second step is required because generated config files such as the Kea config
intentionally keep placeholders like `$KEA_DB_PASSWORD` until deploy time.

Default secrets locations:

- Docker Compose: `.tmp/openchami-secrets.env`
- Quadlets: `/etc/openchami/secrets.env`

Override the path with `OPENCHAMI_SECRETS=/path/to/secrets.env`.

## Local Image Builds

Build the local OCI images explicitly with:

```bash
make build-images
```

Or call the script directly:

```bash
scripts/ops/build-images.sh
scripts/ops/build-images.sh --runtime podman
```

The Docker Compose and quadlet paths now build a local Kea image from Nixpkgs.
The `kea-sync` image is built from an external checkout. The build script will:

- use `KEA_SYNC_SRC` if you set it
- otherwise reuse `../services/kea-sync` if it is already a git checkout
- otherwise clone `https://github.com/aescoubas/kea-sync.git` into that location

Relevant overrides:

- `KEA_SYNC_SRC`
- `KEA_SYNC_CHECKOUT`
- `KEA_SYNC_REPO`

## Other Workflows

### Quadlets

Generate and activate the systemd/Podman profile:

```bash
make deploy METHOD=quadlets
make teardown METHOD=quadlets
```

The quadlet deploy path also uses the Nix `deploy-profile` output and runtime
config rendering.

### Minikube

Generate Helm values and deploy the chart:

```bash
make deploy METHOD=minikube
make teardown METHOD=minikube
```

The Helm chart lives in `ochami-helm/`, and the generated values are produced by
`nix/generators/helm-values.nix`.

### MCP Server

Run the standalone MCP server with:

```bash
nix run .#mcp -- --mode read-only
nix run .#mcp -- --mode read-write --enable-writes
```

### NixOS VM Lab

Run the interactive NixOS VM lab:

```bash
nix run .#lab-driver
```

Build the controller and boot-node VM artifacts explicitly with:

```bash
make build-lab-controller-vm
make build-lab-boot-node-vm
```

The flake also exports the Linux guest system closures directly:

```bash
nix build path:.#lab-controller-system
nix build path:.#lab-boot-node-system
```

The controller VM path is the intended portability boundary for Ubuntu and macOS:
keep the fast Ubuntu host-native compose/libvirt workflow, but move the portable
lab boundary into a Linux VM instead of trying to reproduce Linux PXE host
behavior on Darwin directly.

The interactive lab smoke test remains Linux-only. The standalone controller and
boot-node VM artifacts are the basis of the portable `lab-vm` workflow.

## Development And Verification

Enter the development shell:

```bash
nix develop
```

Build the default package:

```bash
nix build
```

Run the required local verification commands:

```bash
make test
nix flake check
nix build .#docker-compose-yml
nix build .#quadlet-units
nix build .#deploy-profile
```

Additional useful targets:

```bash
make generate
make generate-images
make test-vm
make test-vm-ubuntu
make test-vm-fedora
make test-vm-destroy
```

## Repository Layout

```text
nix/
  services/              Service definitions and shared defaults
  generators/            Docker Compose, Quadlets, and Helm values generators
  images/                OCI image build definitions
  deploy/                Deploy profile generator
  lab/                   NixOS VM lab definitions
  tests/                 NixOS lab smoke test
scripts/ops/             Operational scripts for deploy, teardown, health, and VM setup
ochami/mcp/              Standalone MCP server
ochami-docker-compose/   Generated compose runtime files and rendered configs
ochami-quadlets/         Generated quadlet runtime files and rendered configs
ochami-helm/             Helm chart and runtime assets
libvirt/                 Libvirt VM integration helpers
docs/architecture/       Architecture notes and ADRs
docs/plans/              Roadmap and planning documents
tests/                   Pytest suite
```

## Architecture Notes

Architecture documentation and ADRs live under `docs/architecture/`:

- `docs/architecture/README.md`
- `docs/architecture/overview.md`
- `docs/architecture/compose-pxe-lab.md`

Do not create a top-level `ARCHITECTURE/` directory.
