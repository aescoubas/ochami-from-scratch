# OpenCHAMI From Scratch (Python CLI)

This repository deploys a local OpenCHAMI stack using a Python CLI (`ochami`) with three orchestrators:

- `minikube`
- `quadlets`
- `docker-compose`

The legacy shell entrypoints were removed in favor of Python deploy/teardown workflows.

## Install

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -e .[dev]
```

You can then use either:

- `ochami ...`
- `.venv/bin/python -m ochami.cli ...`

## Quick Start

Deploy with Docker Compose:

```bash
ochami deploy --method docker-compose
```

Deploy with Quadlets:

```bash
ochami deploy --method quadlets
```

Deploy with Minikube:

```bash
ochami deploy --method minikube
```

Teardown:

```bash
ochami teardown --method docker-compose -y
ochami teardown --method quadlets -y
ochami teardown --method minikube -y
```

`--method` is required for both `deploy` and `teardown`.

## Common Deploy Options

```bash
ochami deploy --method minikube \
  --mode hardware \
  --interface ens160 \
  --ip 192.168.50.1 \
  --cidr 24 \
  --dhcp-start 192.168.50.100 \
  --dhcp-end 192.168.50.200
```

Useful flags:

- `--rebuild`
- `--vms N`
- `--nodes-file nodes.csv`
- `--discovery-method magellan`
- `--magellan-subnets ...`
- `--auto-kill` / `--fail-on-conflict`
- `--set-fs-protected-regular` (enabled by default) / `--no-set-fs-protected-regular`

Minikube notes:

- On Linux (`--driver=none`), deploy can auto-adjust `fs.protected_regular` and retry Minikube start for known lock-permission failures.
- Previous `fs.protected_regular` is restored by teardown when it was changed by OpenCHAMI.
- If UDP/67 is already in use, run teardown first or use `--auto-kill`.

## Hardware Node Registration

Register a hardware node after deployment:

```bash
ochami register-node \
  --method minikube \
  --host-ip 192.168.100.2 \
  --mac 00:11:22:33:44:55 \
  --ip 192.168.50.50 \
  --component-id x1000c0s0b0n0 \
  --nid 1000 \
  --bmc-ip 192.168.50.100 \
  --bmc-user root \
  --bmc-pass password
```

## MCP Server

Run the local MCP server from the Python CLI:

```bash
ochami mcp --mode read-only
```

For read-write tools:

```bash
ochami mcp --mode read-write --enable-writes
```

Minikube deployments write MCP defaults to `.openchami-mcp.env`.

## Testing

Run the local test suite:

```bash
make test
```

This runs pytest (`.venv/bin/python -m pytest`).

## VM Integration Loops

Libvirt integration loops are still available:

```bash
make test-vm-ubuntu
make test-vm-fedora
make test-vm
make test-vm-destroy
```

## Repository Layout

Deployment artifacts remain in:

- `ochami-docker-compose/`
- `ochami-helm/`
- `ochami-quadlets/`

Core Python package:

- `ochami/`
