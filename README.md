# OpenCHAMI From Scratch

This repository packages a local OpenCHAMI control plane around:

- Dockerfiles for OCI image builds in `images/<service>/Dockerfile`
- Directly-maintained deployment artifacts in `deploy/compose/`, `deploy/quadlets/`, `deploy/helm/`
- Profile env files in `profiles/*.env`
- Bash operational entry points in `scripts/ops/`

The validated end-to-end local workflow is Docker Compose plus libvirt PXE boot:

1. deploy the stack with `make deploy METHOD=compose`
2. create a libvirt VM with `make create-test-vms COUNT=1`
3. confirm the guest reaches its xname-derived serial login prompt

There is no Python deployment CLI in this repository. The only Python application
entry point is the standalone MCP server in `ochami/mcp/`.

## Deployment Artifacts

Deployment artifacts are directly maintained under `deploy/`:

- `deploy/compose/` -- Docker Compose files and config templates
- `deploy/quadlets/` -- Podman quadlet `.container` files
- `deploy/helm/` -- Helm chart and values

Profile env files under `profiles/*.env` (official, dev, cscs) control image
references, registries, and version tags.

The test-node boot image defaults to `almalinux`. Supported values are:

- `almalinux`
- `ubuntu`
- `opensuse`

Select a different image by passing `TEST_NODE_IMAGE=<name>` to the relevant
`make` target.

## Prerequisites

Most deployment-oriented functionality is Linux-only.

For the validated Docker Compose PXE path, the host needs:

- `buildah` or `docker` (for building OCI images)
- `docker` plus `docker compose`
- `virsh`, `virt-install`, and `qemu-img`
- `curl`, `jq`, `envsubst`, `ss`, `ip`, and `timeout`
- passwordless `sudo` for libvirt network and bridge preparation

Check the compose prerequisites with:

```bash
make check METHOD=compose
sudo -n true
```

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

To switch the test-node boot image for the compose PXE path:

```bash
make deploy METHOD=compose TEST_NODE_IMAGE=ubuntu
make create-test-vms COUNT=1 TEST_NODE_IMAGE=ubuntu
```

The same selector supports `opensuse`, `ubuntu`, and `almalinux` (default).

To build one Go service from a local checkout while keeping the rest of the
selected profile unchanged, pass the source path as a `make` variable:

```bash
make deploy METHOD=compose PROFILE=dev BSS_SRC=/path/to/bss
```

The default stack profile is `official`. That profile pins locally built images to
the upstream refs:

- `smd:v2.19.2`
- `bss:v1.32.2`
- `cloud-init:v1.4.0`
- `pcs:main`
- `kea-sync:main`
- `http-server:latest`
- `tftp:latest`

To opt into the moving `dev` profile instead:

```bash
make deploy METHOD=compose PROFILE=dev
```

The `cscs` profile builds images with a `cscs-` prefix (e.g., `localhost/cscs-bss`)
and generates deployment artifacts that reference the CSCS JFrog registry
(`jfrog.svc.cscs.ch/docker/openchami/cscs-*`). See the [CSCS JFrog Workflow](#cscs-jfrog-workflow)
section below for the full build-push-deploy flow.

This compose path:

- ensures the secrets file exists at `.tmp/openchami-secrets.env`
- builds and loads local OCI images for OpenCHAMI services plus the bundled Kea runtime
- uses `deploy/compose/docker-compose.yml`
- runs `envsubst` on config templates in `deploy/compose/configs/` to inject secrets
- ensures the libvirt PXE network `ochami-pxe-net` exists on bridge `virbr-ochami`
- temporarily pauses conflicting libvirt DHCP networks while PXE is active
- registers default BSS boot parameters from the selected boot artifacts

Create and register a test VM:

```bash
make create-test-vms COUNT=1
```

If existing `ochami-test-node-*` domains are already defined, use a fresh index:

```bash
scripts/ops/create-test-vms.sh --count 1 --start-index 2
```

On the Linux compose/libvirt path, `create-test-vms` also starts one
`sushy-tools` Redfish endpoint per VM on a deterministic loopback address in
`127.84.0.0/16`. Those per-VM BMC addresses are registered in SMD with default
credentials `admin` / `password`, so PCS can drive libvirt power operations
through Redfish. On the compose path, `make deploy` stores the same
`LIBVIRT_BMC_USER` and `LIBVIRT_BMC_PASSWORD` values in
`.tmp/openchami-secrets.env`, and `create-test-vms` plus PCS both consume those
settings unless you override them in the environment. Additional compose VMs
use one node per BMC slot, so the default xnames are `x1000c0s0b0n0`,
`x1000c0s0b1n0`, `x1000c0s0b2n0`, and so on. The libvirt domain names also include the xname, so
the first VM appears as `ochami-test-node-0-x1000c0s0b0n0` in `virsh list`, and
the guest login shell prompt uses that xname directly.

Inspect the guest console:

```bash
sudo virsh --connect qemu:///system console ochami-test-node-0-x1000c0s0b0n0
```

Inside the guest, verify the OpenCHAMI-provided kernel args:

```bash
cat /proc/cmdline
```

The successful path is:

- the console reaches a login prompt for the node xname, such as `x1000c0s0b0n0 login:`
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
sudo virsh --connect qemu:///system destroy ochami-test-node-0-x1000c0s0b0n0 || true
sudo virsh --connect qemu:///system undefine ochami-test-node-0-x1000c0s0b0n0
sudo rm -f /var/lib/libvirt/images/ochami/ochami-test-node-0-x1000c0s0b0n0.qcow2
```

## Secrets And Config Rendering

The compose and quadlet flows render runtime config files with secrets from a
secrets file via `envsubst`. Config templates such as the Kea config intentionally
keep placeholders like `$KEA_DB_PASSWORD` until deploy time.

Default secrets locations:

- Docker Compose: `.tmp/openchami-secrets.env`
- Quadlets / RPM: `/etc/openchami/openchami.env`

Override the path with `OPENCHAMI_SECRETS=/path/to/secrets.env`.

## Local Image Builds

Build the local OCI images explicitly with:

```bash
make build-images
```

Use `PROFILE=dev` if you want the cutting-edge stack instead of the default
`official` profile:

```bash
make build-images PROFILE=dev
```

To override a specific Go service from a local checkout, pass the source path on
the `make` command line:

```bash
make build-images PROFILE=dev SMD_SRC=/path/to/smd
make build-images PROFILE=dev BSS_SRC=/path/to/bss
make build-images PROFILE=dev PCS_SRC=/path/to/power-control
make build-images PROFILE=dev CLOUD_INIT_SRC=/path/to/cloud-init
```

`make deploy` accepts the same override variables and forwards them into the
image build step before the stack starts:

```bash
make deploy METHOD=compose PROFILE=dev SMD_SRC=/path/to/smd
```

Or call the script directly:

```bash
scripts/ops/build-images.sh
scripts/ops/build-images.sh --runtime podman
```

Images are built using Dockerfiles in `images/<service>/Dockerfile` via buildah
(or docker). The Go service images can also consume local checkouts, and the `kea-sync`
image is built from an external checkout. The build script will:

- use `SMD_SRC`, `BSS_SRC`, `PCS_SRC`, and `CLOUD_INIT_SRC` if you set them
- derive an OCI-safe image tag from the current git ref of each local checkout
- use `KEA_SYNC_SRC` if you set it
- otherwise reuse `../services/kea-sync` if it is already a git checkout
- otherwise clone `https://github.com/aescoubas/kea-sync.git` into that location

Relevant overrides:

- `SMD_SRC`
- `BSS_SRC`
- `PCS_SRC`
- `CLOUD_INIT_SRC`
- `KEA_SYNC_SRC`
- `KEA_SYNC_CHECKOUT`
- `KEA_SYNC_REPO`
- `OPENCHAMI_PROFILE`

## RPM Deployment

Build the RPM package. The RPM embeds the quadlet `.container` files for the
selected `PROFILE`, so the image references baked into the RPM match the
profile's registry and prefix:

```bash
# Default (official profile — localhost/* images)
make rpm

# CSCS profile — quadlets reference jfrog.svc.cscs.ch/docker/openchami/cscs-*
make rpm PROFILE=cscs
```

This produces `ochami-from-scratch-<version>-<release>.noarch.rpm`. The RPM
installs quadlet `.container` files, config templates, postgres init scripts,
and operational scripts to their standard system paths.

Install on a target host (AlmaLinux / RHEL / Fedora):

```bash
sudo dnf install ./ochami-from-scratch-*.noarch.rpm
```

The RPM `%post` scriptlet runs `bootstrap.sh` automatically, which:

- creates `/etc/openchami/artifacts/`
- generates random database passwords in `/etc/openchami/openchami.env`
- reloads systemd so quadlet units are visible

For the default (official) profile, images must be available in the local
container store before starting services:

```bash
# Build all images (loads them into the local container runtime automatically)
make build-images

# To load images on a remote host via SSH, export them first, then:
./scripts/ops/load-images.sh --remote user@host --ssh-key ~/.ssh/key /path/to/image-archives
```

For the CSCS profile, the quadlets reference JFrog images directly, so podman
pulls them automatically on first start (requires registry access).

Start the OpenCHAMI stack:

```bash
sudo systemctl start openchami.target
```

Check service health:

```bash
systemctl list-units 'openchami-*' --no-pager
journalctl -u smd -u bss -u kea -u pcs --no-pager -n 50
```

## CSCS JFrog Workflow

The `cscs` profile adds a `cscs-` prefix to all image names and sets the
registry to `jfrog.svc.cscs.ch/docker/openchami`. This means:

- OCI images are built as `localhost/cscs-<name>:<tag>`
- Deployment artifacts (quadlets, compose, helm) reference
  `jfrog.svc.cscs.ch/docker/openchami/cscs-<name>:<tag>`

### Build and push images

```bash
# 1. Build CSCS-prefixed images
make build-images PROFILE=cscs

# 2. Verify
sudo podman images | grep cscs-

# 3. Push to JFrog (dry run first)
./scripts/ops/push-images.sh --registry jfrog.svc.cscs.ch/docker/openchami --prefix cscs- --dry-run

# 4. Push for real
./scripts/ops/push-images.sh --registry jfrog.svc.cscs.ch/docker/openchami --prefix cscs-
```

### Build CSCS RPM

```bash
make rpm PROFILE=cscs
```

The resulting RPM contains quadlet files with `Image=jfrog.svc.cscs.ch/...`
references. On the target host, podman pulls images from JFrog automatically
when `systemctl start openchami.target` runs.

### Inspect deployment artifacts

```bash
# View CSCS quadlet image references
grep Image= deploy/quadlets/containers/*.container

# View CSCS docker-compose
cat deploy/compose/docker-compose.yml
```

## Other Workflows

### Quadlets

Generate and activate the systemd/Podman profile:

```bash
make deploy METHOD=quadlets
make teardown METHOD=quadlets
```

### Minikube

Deploy the Helm chart:

```bash
make deploy METHOD=minikube
make teardown METHOD=minikube
```

The Helm chart lives in `deploy/helm/`.

### MCP Server

Run the standalone MCP server with:

```bash
python -m ochami.mcp --mode read-only
python -m ochami.mcp --mode read-write --enable-writes
```

## Development And Verification

Run the required local verification commands:

```bash
make test
```

Additional useful targets:

```bash
make build-images
```

## Repository Layout

```text
images/                  Dockerfiles for OCI image builds (images/<service>/Dockerfile)
deploy/
  compose/               Docker Compose files and config templates
  quadlets/              Podman quadlet .container files and configs
  helm/                  Helm chart and values
profiles/                Profile env files (official.env, dev.env, cscs.env)
scripts/ops/             Operational scripts for deploy, teardown, health, and VM setup
ochami/mcp/              Standalone MCP server
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
