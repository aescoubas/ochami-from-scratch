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

The runtime files under `ochami-docker-compose/` and `ochami-quadlets/` are
generated outputs and rendered configs. They are not hand-maintained source files.

## Prerequisites

Most deployment-oriented functionality is Linux-only.

For the validated Docker Compose PXE path, the host needs:

- `nix`
- `docker` plus `docker compose`
- `virsh`, `virt-install`, and `qemu-img`
- `curl`, `jq`, `envsubst`, `ss`, and `ip`
- passwordless `sudo` for libvirt network and bridge preparation

Check the compose prerequisites with:

```bash
make check METHOD=compose
sudo -n true
```

`nix develop` is useful for Python/package work, but it does not replace the host
requirements above. In particular, Docker, libvirt, and `envsubst` are expected to
exist on the host.

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
- builds and loads local OCI images for OpenCHAMI-owned services
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

The `kea-sync` image is built from an external checkout. The build script will:

- use `KEA_SYNC_SRC` if you set it
- otherwise reuse `../services/kea-sync` if it is already a git checkout
- otherwise clone `git@github.com:OpenCHAMI/kea-sync.git` into that location

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

The lab smoke test is exported as a Linux-only flake check.

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
