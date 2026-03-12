# OpenCHAMI From Scratch

This repository deploys a local OpenCHAMI bare-metal provisioning stack using three
deployment methods, all driven by Nix-generated artifacts and Bash operational scripts:

- **Docker Compose** — `nix build .#docker-compose-yml`
- **Podman Quadlets** — `nix build .#quadlet-units` + `nix build .#deploy-profile`
- **Helm/Minikube** — `nix build .#helm-values`

## Architecture

```
nix/services/*.nix       ← single source of truth (ports, images, env, deps)
nix/generators/*.nix     ← produces docker-compose.yml, .container files, values.yaml
nix/images/*.nix         ← OCI image builds (Go services + utilities)
nix/deploy/profile.nix   ← systemd unit generator for quadlet deployments
nix/lab/*.nix            ← NixOS VM lab (controller + boot node)
scripts/ops/             ← bash operational scripts (deploy, teardown, health check)
ochami/mcp/              ← standalone MCP server for OpenCHAMI control
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

## Bash Scripts

All runtime operations use `scripts/ops/`:

| Script | Purpose |
|--------|---------|
| `deploy.sh` | Top-level orchestrator: deps → secrets → start → health → register |
| `teardown.sh` | Tear down by method |
| `check-deps.sh` | Verify required tools are installed |
| `health-check.sh` | Wait for services to become healthy |
| `register-nodes.sh` | Register nodes via SMD/BSS curl calls |
| `register-bss-defaults.sh` | Register default boot parameters |
| `lab-setup.sh` | Libvirt network + VM lifecycle |

All scripts support `--dry-run` and source `lib/common.sh` for shared functions.

## MCP Server

The MCP server provides local control-plane access to OpenCHAMI deployments:

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

## Testing

```bash
make test          # pytest in Nix dev shell
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
  services/          Service definitions (single source of truth)
  generators/        Artifact generators (docker-compose, quadlets, helm)
  images/            OCI image build definitions
  deploy/            Deploy profile (systemd units)
  lab/               NixOS VM lab (controller, boot-node, secrets)
  tests/             NixOS VM smoke tests
scripts/ops/         Bash operational scripts
ochami/mcp/          MCP server (standalone Python, stdlib only)
ochami-helm/         Helm chart templates
tests/               pytest test suite
```
