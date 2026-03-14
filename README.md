# OpenCHAMI From Scratch

This repository deploys a local OpenCHAMI bare-metal provisioning stack using three
deployment methods, all driven by Nix-generated artifacts and Bash operational scripts:

- **Docker Compose** — `nix build .#docker-compose-yml`
- **Podman Quadlets** — `nix build .#quadlet-units` + `nix build .#deploy-profile`
- **Helm/Minikube** — `nix build .#helm-values`

## Architecture

`nix/services/*.nix` is the single source of truth for all service definitions
(ports, images, environment variables, volumes, dependencies, health checks).
Deployment artifacts are generated from these definitions — never hand-written.

```
nix/
  services/*.nix         ← single source of truth (ports, images, env, deps)
  services/defaults.nix  ← shared constants (ports, databases, secrets, image refs)
  generators/            ← produces docker-compose.yml, .container files, values.yaml
  images/                ← OCI image builds (Go services + utilities)
  deploy/profile.nix     ← systemd unit generator for quadlet deployments
  lab/                   ← NixOS VM lab (controller + boot node + secrets)
  tests/lab-smoke.nix    ← NixOS VM smoke test

scripts/ops/             ← bash operational scripts (deploy, teardown, health check)
ochami/mcp/              ← standalone MCP server (Python, stdlib only)
ochami-helm/             ← Helm chart templates for Minikube
```

## Install

Nix is the primary workflow:

```bash
nix develop    # enter dev shell with all tools
nix build      # build the MCP server package
nix flake check
```

## Quick Start

### Deploy with Docker Compose

```bash
make deploy METHOD=compose
```

After a successful compose deploy, create one or more libvirt PXE test VMs with:

```bash
make create-test-vms COUNT=1
# or:
scripts/ops/create-test-vms.sh --count 2
```

### Deploy with Quadlets (systemd + Podman)

```bash
make deploy METHOD=quadlets
```

### Deploy with Minikube

```bash
make deploy METHOD=minikube
```

### Teardown

```bash
make teardown METHOD=compose
make teardown METHOD=quadlets
make teardown METHOD=minikube
```

### Check Dependencies

```bash
make check METHOD=compose
```

## Generate Artifacts

Build deployment artifacts from the Nix service definitions:

```bash
# Generate all artifacts
make generate

# Or individually
nix build .#docker-compose-yml --print-out-paths
nix build .#quadlet-units --print-out-paths
nix build .#helm-values --print-out-paths
nix build .#deploy-profile --print-out-paths
```

## Operational Scripts

All runtime operations use `scripts/ops/`:

| Script | Purpose |
|--------|---------|
| `deploy.sh` | Top-level orchestrator: deps → secrets → start → health → register |
| `teardown.sh` | Tear down by method |
| `check-deps.sh` | Verify required tools are installed (does not install) |
| `health-check.sh` | Wait for services to become healthy |
| `create-test-vms.sh` | Ensure libvirt PXE test VMs exist, are registered, and are restarted into PXE |
| `register-nodes.sh` | Register nodes via SMD/BSS curl calls |
| `register-bss-defaults.sh` | Register default boot parameters |
| `lab-setup.sh` | Libvirt PXE network lifecycle |

All scripts support `--dry-run` and source `lib/common.sh` for shared functions
(logging, `wait_for_url`, `generate_secret`, `ensure_secrets_file`).

For Docker Compose PXE boot, the libvirt network is now named `ochami-pxe-net` and
its bridge is `virbr-ochami`. During deploy, "prepare the bridge" means:

- Ensure the `ochami-pxe-net` libvirt network exists on `virbr-ochami`
- Stop conflicting libvirt DHCP networks temporarily
- Attach a temporary dummy port if needed so the bridge reports carrier and Kea can bind

## MCP Server

The MCP server provides local control-plane access to OpenCHAMI deployments.
It is a standalone Python package with zero external dependencies (stdlib only).

```bash
nix run .#mcp -- --mode read-only
nix run .#mcp -- --mode read-write --enable-writes
```

## NixOS VM Lab

Run an interactive NixOS VM lab with a controller and boot node:

```bash
nix run .#lab-driver
```

Or run the smoke test:

```bash
nix flake check   # includes lab-smoke test on Linux
```

The lab controller runs dnsmasq (DHCP/TFTP), nginx (boot artifacts), and has Podman
available for container-based service deployment.

## Testing

```bash
make test          # pytest in Nix dev shell (83 tests)
```

## VM Integration Tests

```bash
make test-vm-ubuntu
make test-vm-fedora
make test-vm
make test-vm-destroy
```

## Repository Layout

```
nix/
  services/              Service definitions (single source of truth)
  generators/            Artifact generators (docker-compose, quadlets, helm)
  images/                OCI image build definitions
  deploy/                Deploy profile (systemd units + activate/deactivate)
  lab/                   NixOS VM lab (controller, boot-node, secrets, images)
  tests/                 NixOS VM smoke tests
scripts/ops/             Bash operational scripts
  lib/common.sh          Shared functions (logging, wait, secrets)
ochami/mcp/              MCP server (standalone Python, stdlib only)
ochami-helm/             Helm chart templates for Minikube
ochami-docker-compose/   Static configs (kea, nginx) for Docker Compose
ochami-quadlets/         Static configs for Podman Quadlets
libvirt/                 Libvirt VM integration test scripts
docs/plans/              Roadmap and planning docs
tests/                   pytest test suite
```
