# OpenCHAMI From Scratch (Python CLI)

This repository deploys a local OpenCHAMI stack using a Python CLI (`ochamifs`) with three orchestrators:

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

- `ochamifs ...`
- `.venv/bin/python -m ochami.cli ...`

## Quick Start

Deploy with Docker Compose:

```bash
ochamifs deploy --method docker-compose
```

Deploy with Quadlets:

```bash
ochamifs deploy --method quadlets
```

Deploy with Minikube:

```bash
ochamifs deploy --method minikube
```

Teardown:

```bash
ochamifs teardown --method docker-compose -y
ochamifs teardown --method quadlets -y
ochamifs teardown --method minikube -y
```

`--method` is required for both `deploy` and `teardown`.

## Common Deploy Options

```bash
ochamifs deploy --method minikube \
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
ochamifs register-node \
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
ochamifs mcp --mode read-only
```

For read-write tools:

```bash
ochamifs mcp --mode read-write --enable-writes
```

Deployments write MCP defaults to `.openchami-mcp.env`:

- `minikube`: `OPENCHAMI_BASE_URL=http://<host_ip>:30080`
- `docker-compose`: `OPENCHAMI_BASE_URL=http://<host_ip>:80`
- `quadlets`: `OPENCHAMI_BASE_URL=http://<host_ip>:80`

For Codex MCP client integration (`~/.codex/config.toml`), configure the server
module entrypoint (the legacy `scripts/mcp/openchami_mcp_server.py` path was
removed during the Python CLI migration):

```toml
[mcp_servers.openchami]
command = "/home/escoubas/git_repos/github/aescoubas/ochami-from-scratch/.venv/bin/python"
args = [
  "-m", "ochami.mcp.server",
  "--mode", "read-write",
  "--base-url", "http://192.168.100.2:30080",
  "--timeout", "10",
  "--no-write-ack"
]
startup_timeout_sec = 60
```

Notes:

- Use the `OPENCHAMI_BASE_URL` value from `.openchami-mcp.env` when available.
- For safer defaults, prefer `--mode read-only`.
- In read-write mode, prefer `--enable-writes` (or set `OPENCHAMI_MCP_ENABLE_WRITES=true`) instead of `--no-write-ack`.

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
