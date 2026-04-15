# OpenCHAMI From Scratch

This repository packages a local OpenCHAMI control plane around:

- Dockerfiles for OCI image builds in `images/<service>/Dockerfile`
- Directly-maintained deployment artifacts in `deploy/compose/`, `deploy/quadlets/`, `deploy/helm/`
- Profile env files in `profiles/*.env`
- Bash operational entry points in `scripts/ops/`

## Quick Start: Virtual Lab

The fastest way to get a complete OpenCHAMI environment is the virtual lab. It
creates an AlmaLinux 9 server VM running the full stack via RPM + podman
quadlets, then boots PXE client VMs from it:

```bash
make lab
```

This runs end-to-end: builds the RPM and OCI images, provisions the server VM,
loads images, starts services, and creates PXE boot client VMs.

Individual steps:

```bash
make lab-server            # Build RPM + images, create AlmaLinux VM, start services
make lab-clients COUNT=2   # Create 2 PXE boot client VMs
make lab-status            # Show VM states and service health
make lab-destroy           # Tear everything down
```

The lab architecture:

```text
Host (your laptop)
+-- libvirt
    +-- ochami-lab-server (AlmaLinux 9)
    |   +-- NIC 1: default network (SSH from host)
    |   +-- NIC 2: ochami-lab-net (192.168.200.0/24, DHCP/PXE)
    |   +-- RPM installed, OCI images in podman
    |   +-- openchami.target running
    |
    +-- ochami-lab-client-0 (PXE boot from server)
    +-- ochami-lab-client-1 (PXE boot from server)
```

Prerequisites: `virsh`, `virt-install`, `qemu-img`, `podman`, `make`, `curl`,
`ssh`. The lab script handles everything else.

After `make lab-server`, connect to the server:

```bash
ssh -i ~/.local/state/openchami/lab/ssh/id_ed25519 almalinux@<server-ip>
```

Watch a client PXE boot:

```bash
sudo virsh console ochami-lab-client-0
```

## Deployment Methods

| Method | Use Case | Command |
|--------|----------|---------|
| **Virtual Lab** | End-to-end testing with RPM on AlmaLinux VM | `make lab` |
| **Quadlets/RPM** | Production RHEL systems | `make rpm` then `systemctl start openchami.target` |

## Profiles

Profile env files under `profiles/*.env` control image references, registries,
and version tags.

| Profile | Image Prefix | Registry | Refs |
|---------|-------------|----------|------|
| `official` (default) | none | `localhost` | Pinned releases (smd:v2.19.2, bss:v1.32.2, cloud-init:v1.4.0) |
| `dev` | none | `localhost` | All services track `main` |
| `cscs` | `cscs-` | `jfrog.svc.cscs.ch/docker/openchami` | Same as official |

## Secrets And Config Rendering

The compose and quadlet flows render runtime config files with secrets from a
secrets file via `envsubst`. Config templates keep placeholders like
`$KEA_DB_PASSWORD` until deploy time.

Default secrets locations:

- Docker Compose: `.tmp/openchami-secrets.env`
- Quadlets / RPM: `/etc/openchami/openchami.env`

Override the path with `OPENCHAMI_SECRETS=/path/to/secrets.env`.

## Local Image Builds

```bash
make build-images                                    # Official profile
make build-images PROFILE=dev                        # Dev profile
make build-images PROFILE=dev SMD_SRC=/path/to/smd   # Local source override
```

Images are built using Dockerfiles in `images/<service>/Dockerfile` via buildah
or docker. Supported source overrides: `SMD_SRC`, `BSS_SRC`, `PCS_SRC`,
`CLOUD_INIT_SRC`, `KEA_SYNC_SRC`.

## RPM Deployment

Build the RPM:

```bash
make rpm                   # Official profile
make rpm PROFILE=cscs      # CSCS JFrog profile
```

The RPM also stages the host CLIs `ochami` and `magellan`. By default,
`magellan` is built from upstream tag `v0.5.1`; override `MAGELLAN_SRC`,
`MAGELLAN_REPO`, or `MAGELLAN_REF` if you need a different checkout or ref.

Install on AlmaLinux / RHEL / Fedora:

```bash
sudo rpm -ivh ./openchami-*.x86_64.rpm
```

The RPM `%post` scriptlet runs `bootstrap.sh` which creates
`/etc/openchami/artifacts/`, `/etc/openchami/artifacts/rustfs-{data,logs}/`,
and `/etc/openchami/tftpboot/`, generates random database and RustFS
credentials in `/etc/openchami/openchami.env`, and reloads systemd.

After install, the host has both CLIs available:

```bash
ochami version
magellan version
```

Images must be available in podman before starting:

```bash
make build-images
# To load on a remote host:
./scripts/ops/load-images.sh --remote user@host --ssh-key ~/.ssh/key /path/to/archives
```

Start:

```bash
sudo systemctl start openchami.target
```

## CSCS JFrog Workflow

```bash
# Build CSCS-prefixed images
make build-images PROFILE=cscs

# Push to JFrog
./scripts/ops/push-images.sh --registry jfrog.svc.cscs.ch/docker/openchami --prefix cscs-

# Build RPM with JFrog image references
make rpm PROFILE=cscs
```

The RPM quadlets reference `jfrog.svc.cscs.ch/...` so podman pulls
automatically on `systemctl start openchami.target`.

The CSCS quadlets currently pin `kea-sync` to
`jfrog.svc.cscs.ch/docker/openchami/cscs-kea-sync:v0.1.0`. The RPM also ships
`openchami-mcp.container`, which follows
`jfrog.svc.cscs.ch/docker/openchami/cscs-openchami-mcp:v0.1.1`, runs it in HTTP
mode on `127.0.0.1:8081`, and enables read-write MCP access on deployed hosts.

## Development And Verification

```bash
make test           # Run pytest suite
make build-images   # Build all OCI images
make lab-status     # Check lab VM health
```

## Repository Layout

```text
images/                  Dockerfiles for OCI image builds
deploy/
  compose/               Docker Compose files and config templates
  quadlets/              Podman quadlet .container files and configs
  helm/                  Helm chart and values
profiles/                Profile env files (official.env, dev.env, cscs.env)
scripts/ops/             Operational scripts
  lab.sh                 Virtual test lab lifecycle
  deploy.sh              Deployment orchestrator
  build-images.sh        OCI image builder (buildah/docker)
  build-boot-artifacts.sh  PXE boot artifact downloader
  push-boot-artifacts.sh   Push boot artifacts to remote server
  register-nodes.sh      Register a node with SMD
  register-bss-defaults.sh  Register BSS boot parameters
  create-test-vms.sh     Compose PXE test VM creator
  create-demo-vm.sh      Single demo VM creator
ochami/mcp/              Standalone MCP server
tests/                   Pytest suite
docs/architecture/       Architecture notes and ADRs
docs/plans/              Roadmap and planning documents
```

## Quickstart: RPM + RHEL Host

This walkthrough deploys OpenCHAMI on a bare RHEL/AlmaLinux host using the RPM
package with CSCS JFrog images, then registers a bare-metal node for PXE boot.

### Prerequisites

- RHEL 9 (or AlmaLinux/Fedora) host with `podman` and `jq` installed
- Network connectivity to `jfrog.svc.cscs.ch` (for pulling OCI images)
- Network connectivity (routed or L2) to the bare-metal node's BMC/NIC

### 1. Build and install the RPM

On your build machine:

```bash
make rpm-clean && make rpm
scp openchami-0.1.3-1.x86_64.rpm <rhel-host>:~/
```

On the RHEL host:

```bash
sudo rpm -ivh ~/openchami-*.x86_64.rpm
```

If upgrading from a previous package name (`ochami-from-scratch`), remove it
first: `sudo rpm -e ochami-from-scratch`.

The `%post` scriptlet creates `/etc/openchami/artifacts/`,
`/etc/openchami/artifacts/rustfs-{data,logs}/`, and
`/etc/openchami/tftpboot/`, generates random database and RustFS credentials in
`/etc/openchami/openchami.env`, and reloads systemd.

### 2. Start the stack

```bash
sudo systemctl start openchami.target
```

Podman pulls all OCI images from JFrog on first start. Verify:

```bash
systemctl list-dependencies openchami.target
```

All init services (`bss-init`, `smd-init`, `kea-init`) should show ○ (completed)
and all runtime services should show ● (running).

Verify the artifact endpoints:

```bash
curl -sf http://localhost:80/boot.ipxe -o /dev/null && echo "http-server OK"
curl -sf http://localhost:9000/health -o /dev/null && echo "rustfs S3 OK"
curl -sf http://localhost:9001/rustfs/console/health -o /dev/null && echo "rustfs console OK"
```

The packaged `openchami-mcp` service starts with `openchami.target` on hosts
such as `msws`. It runs as a localhost-only HTTP MCP endpoint. Verify it like
this:

```bash
curl -sf http://127.0.0.1:8081/healthz && echo "openchami-mcp OK"
curl -sS \
  -H 'Content-Type: application/json' \
  http://127.0.0.1:8081/mcp \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl","version":"0"}}}' | jq .
```

`openchami-mcp` is not exposed through nginx. The RPM runs it as a dedicated
localhost-bound HTTP service so systemd can manage it like the rest of the
stack without the old FIFO/stdin bridge. In this deployment, `openchami-mcp`
talks to SMD over `https://localhost:27779` and skips certificate verification
for that one backend because SMD uses a localhost self-signed certificate.
For Codex, Claude Code, and Gemini CLI client configuration, including SSH
tunnel patterns for this localhost-only endpoint, see the `openchami-mcp`
repository README.

### 3. Open firewall ports

RHEL/AlmaLinux enables `firewalld` by default. The PXE boot chain requires
several ports to be reachable from the node. Without these, the node gets a DHCP
lease (Kea uses raw sockets that bypass the firewall) but cannot TFTP-download
iPXE or reach any HTTP service — causing a silent timeout after DHCP.

```bash
sudo firewall-cmd --add-service=tftp --permanent        # TFTP (port 69/udp, iPXE firmware)
sudo firewall-cmd --add-port=69/udp --permanent          # explicit UDP rule for TFTP data
sudo firewall-cmd --add-port=80/tcp --permanent           # HTTP (nginx: kernel, initrd, boot.ipxe)
sudo firewall-cmd --add-port=9000/tcp --permanent         # RustFS S3 API
sudo firewall-cmd --add-port=9001/tcp --permanent         # RustFS console
sudo firewall-cmd --add-port=27777/tcp --permanent        # cloud-init metadata service
sudo firewall-cmd --add-port=27778/tcp --permanent        # BSS (boot script service)
sudo firewall-cmd --add-port=27779/tcp --permanent        # SMD (state management database)
sudo firewall-cmd --add-port=28007/tcp --permanent        # PCS (power control service)
sudo firewall-cmd --reload
```

Verify:

```bash
sudo firewall-cmd --list-all
# Should show: services: ... tftp
# Should show: ports: 69/udp 80/tcp 9000/tcp 9001/tcp 27777/tcp 27778/tcp 27779/tcp 28007/tcp
```

### 4. Install iPXE boot firmware

The TFTP server ships with an empty root directory. PXE-booting nodes need iPXE
firmware (`ipxe.efi` for UEFI, `undionly.kpxe` for legacy BIOS) to chainload
into the BSS boot script. Install iPXE and copy the binaries:

```bash
sudo dnf install -y ipxe-bootimgs-x86
sudo cp /usr/share/ipxe/ipxe-x86_64.efi  /etc/openchami/tftpboot/ipxe.efi
sudo cp /usr/share/ipxe/undionly.kpxe     /etc/openchami/tftpboot/undionly.kpxe
```

The TFTP quadlet mounts `/etc/openchami/tftpboot` into the container at
`/srv/tftp`. Verify the files are served:

```bash
curl -sf tftp://localhost/ipxe.efi -o /dev/null && echo OK
```

### 5. Build and push the boot image

The HTTP server needs a kernel and root filesystem to serve to PXE-booting
nodes. Boot images are built using `mkosi` in the
[openchami-image-building](https://github.com/aescoubas/openchami-image-building)
repository, which produces a minimal openSUSE Leap 15.6 system as a compressed
cpio archive.

Use the unstripped vanilla image as the default. The older stripped image is
kept for comparison only and is no longer the recommended node image.

On your build machine (requires `mkosi` and `zstd`):

```bash
cd openchami-image-building

# Build the default openSUSE Leap cpio image
make build-leap-live-vanilla
```

Then push the artifacts to the RHEL host using `push-boot-artifacts.sh` from
this repository:

```bash
# From ochami-from-scratch/
make push-boot-artifacts HOST=<RHEL_HOST> \
  ARTIFACTS_DIR=<path-to>/openchami-image-building/mkosi/opensuse-leap-live-vanilla/mkosi.output \
  IMAGE_NAME=opensuse-vanilla
```

Or call the script directly:

```bash
SSH_USER=root scripts/ops/push-boot-artifacts.sh \
  --host <RHEL_HOST> \
  --artifacts-dir <path-to>/openchami-image-building/mkosi/opensuse-leap-live-vanilla/mkosi.output \
  --image-name opensuse-vanilla
```

This rsyncs the artifacts to `/etc/openchami/artifacts/opensuse-vanilla/` on the server:

```text
/etc/openchami/artifacts/opensuse-vanilla/
├── opensuse-leap-live-vanilla-vmlinuz   (14 MB, kernel)
└── opensuse-leap-live-vanilla.cpio.zst  (234 MB, compressed rootfs)
```

Verify they are served:

```bash
curl -sf -o /dev/null -w "%{http_code}" http://localhost:80/artifacts/opensuse-vanilla/opensuse-leap-live-vanilla-vmlinuz
# Should return 200
curl -sf -o /dev/null -w "%{http_code}" http://localhost:80/artifacts/opensuse-vanilla/opensuse-leap-live-vanilla.cpio.zst
# Should return 200
```

To serve the same image set through RustFS instead of nginx, upload the
artifacts into a RustFS bucket and point BSS at the S3-style object URLs.

Create a bucket and mirror the vanilla image into RustFS on the RHEL host:

```bash
set -a
source /etc/openchami/openchami.env
set +a

export MC_HOST_rustfs="http://${RUSTFS_ACCESS_KEY}:${RUSTFS_SECRET_KEY}@127.0.0.1:9000"

podman run --rm --network host -e MC_HOST_rustfs \
  docker.io/minio/mc mb --ignore-existing rustfs/opensuse-vanilla

podman run --rm --network host -e MC_HOST_rustfs \
  -v /etc/openchami/artifacts:/artifacts:ro \
  docker.io/minio/mc mirror --overwrite /artifacts/opensuse-vanilla rustfs/opensuse-vanilla

podman run --rm --network host -e MC_HOST_rustfs \
  docker.io/minio/mc anonymous set download rustfs/opensuse-vanilla
```

Verify the RustFS-backed URLs directly:

```bash
curl -sf -o /dev/null -w "%{http_code}" http://localhost:9000/opensuse-vanilla/opensuse-leap-live-vanilla-vmlinuz
# Should return 200
curl -sf -o /dev/null -w "%{http_code}" http://localhost:9000/opensuse-vanilla/opensuse-leap-live-vanilla.cpio.zst
# Should return 200
```

The RustFS quadlet uses the same host artifact root as nginx. It stores S3 data
under `/etc/openchami/artifacts/rustfs-data/` and logs under
`/etc/openchami/artifacts/rustfs-logs/`, so both artifact-serving paths stay on
the same disk without mixing S3 metadata into the static file tree. The quadlet
sets `RUSTFS_OBS_LOGGER_LEVEL=warn`, keeps stdout mirroring enabled, and uses
`RUST_LOG=warn,rustfs::server::http=debug` so request logs still reach both the
RustFS log files and the host `journalctl -u rustfs` output without the full
RustFS debug stream.

The image boots directly into RAM — the kernel unpacks the cpio as the root
filesystem with systemd as init. NetworkManager handles DHCP in userspace
(wicked is disabled via preset). Cloud-init then contacts the metadata
service for per-node configuration. Default root password: `openchami`.

### 6. Register the node in SMD

Register the node's **PXE NIC** ethernet interface (MAC + IP) and component.

**Important:** Use the MAC address of the node's PXE NIC, not the BMC MAC. The
BMC typically has a static IP on a management network and is not involved in PXE
boot. The PXE NIC MAC is what appears in DHCP DISCOVER packets — check Kea logs
(`journalctl -u kea.service`) if unsure which MAC the node is using.

The IP address must fall within the Kea DHCP subnet configured in step 8 so that
kea-sync can create a DHCP reservation. It should be on the same L2 network as
the RHEL host's interface.

Using the `register-nodes.sh` script:

```bash
scripts/ops/register-nodes.sh \
  --xname <XNAME> --mac <PXE_MAC> --ip <NODE_IP> --bmc-ip <BMC_IP>
```

Or via Make:

```bash
make register-nodes XNAME=<XNAME> MAC=<PXE_MAC> IP=<NODE_IP> BMC_IP=<BMC_IP>
```

The script registers the ethernet interface, component, and BMC Redfish endpoint
in SMD. Omit `--bmc-ip` if there is no BMC.

Verify:

```bash
curl -kfs https://localhost:27779/hsm/v2/State/Components/<XNAME> | jq .
curl -kfs https://localhost:27779/hsm/v2/Inventory/EthernetInterfaces | jq .
```

### 7. Register boot parameters in BSS

Register boot parameters for a specific MAC address using
`register-bss-defaults.sh`:

```bash
scripts/ops/register-bss-defaults.sh \
  --mac <PXE_MAC> \
  --image-name opensuse-vanilla \
  --kernel opensuse-leap-live-vanilla-vmlinuz \
  --initrd opensuse-leap-live-vanilla.cpio.zst \
  --kernel-params "console=ttyS0,115200n8 console=tty0"
```

Or via Make:

```bash
make register-bss-defaults MAC=<PXE_MAC>
```

The script constructs artifact URLs using the server's IP
(`HOST_IP` env var, defaults to `192.168.100.1`) and registers them with BSS.
Without `--mac`, it registers a "Default" fallback entry instead.

To use RustFS instead of nginx for the kernel and initrd, override the artifact
base URL with the RustFS bucket root. Add `--mac` when testing a single node,
or omit it to make RustFS-backed URLs the default for all nodes:

```bash
ARTIFACT_BASE_URL="http://${HOST_IP:-192.168.100.1}:9000/opensuse-vanilla" \
scripts/ops/register-bss-defaults.sh \
  --mac <PXE_MAC> \
  --image-name opensuse-vanilla \
  --kernel opensuse-leap-live-vanilla-vmlinuz \
  --initrd opensuse-leap-live-vanilla.cpio.zst \
  --kernel-params "console=ttyS0,115200n8 console=tty0"
```

Verify the boot script BSS will serve to this MAC:

```bash
curl -sf "http://localhost:27778/boot/v1/bootscript?mac=<PXE_MAC>&arch=x86_64"
```

This should return an iPXE script with `kernel` and `initrd` lines pointing to
your server. The `arch` parameter is not part of the boot parameters we
registered — the MAC alone selects the entry. BSS uses `arch` only to determine
the iPXE script format in the response. iPXE passes it automatically when
fetching the boot script at boot time.

When booting from RustFS, the returned `kernel` and `initrd` lines should use
`http://<host>:9000/<bucket>/...` URLs. You can confirm node fetches with:

```bash
journalctl -u rustfs -g 'uri=/opensuse-vanilla/'
journalctl -u rustfs -g 'real_ip=<NODE_IP>'
```

### 8. Verify kea-sync created the DHCP reservation

Kea-sync polls SMD every 10 seconds and creates DHCP host reservations in Kea
for nodes whose IP falls within a configured Kea subnet. Check that it picked up
the node:

```bash
journalctl -u kea-sync.service --no-pager -n 5
```

Look for `desired=1 managed=1` in the sync output. Then confirm the reservation
in Kea:

```bash
curl -s http://localhost:8000/ \
  -H 'Content-Type: application/json' \
  -d '{"command": "reservation-get-all", "service": ["dhcp4"], "arguments": {"subnet-id": 1}}' \
  | jq .
```

You should see a reservation with the node's PXE MAC, IP, and hostname.

If `desired=0`, the node's IP does not fall within any Kea subnet — check that
the Kea subnet (step 9) matches the network registered in SMD (step 6).

### 9. Network configuration

Several configuration files contain network-specific values that must match your
environment. The RPM ships defaults for a lab network; for bare-metal deployments
you must update these **before** starting the stack (or rebuild the RPM).

**Kea DHCP** (`deploy/quadlets/configs/kea-dhcp4.conf`):

The `subnet4` entry must match the **L2 network of the PXE NIC**, which is the
same network as the RHEL host's interface. This is not necessarily the BMC
management network. Kea matches incoming DHCP packets to subnets based on the
interface they arrive on — if the subnet doesn't match, Kea logs
`failed to select a subnet for incoming packet` and the node never gets an IP.

Key fields:

- **`subnet4[].subnet`** — L2 network of the RHEL host interface (e.g.
  `148.187.1.64/28`). Run `ip -4 addr show` on the RHEL host to find this.
- **`subnet4[].pools`** — DHCP pool range within that subnet (exclude the host
  IP and gateway)
- **`subnet4[].option-data` routers** — the subnet's default gateway
- **`subnet4[].next-server`** — RHEL host IP (tells PXE firmware where to TFTP)
- **`client-classes` iPXE boot-file-name** — BSS URL:
  `http://<SERVER_IP>:27778/boot/v1/bootscript?mac=${mac}`

**BSS** (`deploy/quadlets/containers/bss.container`):

- **`BSS_ADVERTISE_ADDRESS`** — RHEL host's routable IP
- **`BSS_IPXE_SERVER`** — RHEL host's routable IP

**iPXE fallback** (`deploy/quadlets/configs/boot.ipxe`):

- **`base-url`** — `http://<SERVER_IP>:80`

After editing, either rebuild the RPM or copy the files directly and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart kea.service bss.service
```

### Boot chain summary

```text
1. Node powers on, PXE firmware sends DHCP DISCOVER
2. Kea responds with:
   - IP lease from the subnet pool
   - next-server = RHEL host IP (for TFTP)
   - boot-file-name = ipxe.efi (UEFI) or undionly.kpxe (BIOS)
3. PXE firmware TFTP-downloads iPXE from the RHEL host
4. iPXE starts, sends a second DHCP request (identified by option 77 "iPXE")
5. Kea matches the iPXE client class, responds with:
   - boot-file-name = http://<SERVER_IP>:27778/boot/v1/bootscript?mac=<MAC>
6. iPXE fetches the boot script from BSS
7. BSS returns an iPXE script with kernel + initrd (cpio) URLs
8. iPXE downloads kernel (14 MB) + cpio rootfs (244 MB) over HTTP
9. Kernel unpacks the cpio into RAM, finds /init (systemd)
10. systemd starts → NetworkManager requests DHCP lease
11. cloud-init contacts metadata service → sets hostname, DNS, packages
12. live openSUSE Leap system running entirely in RAM
```

### 10. Configure cloud-init metadata

The cloud-init metadata service (port 27777) provides per-node configuration to
nodes at boot. It uses in-memory storage, so data must be repopulated after any
service restart. Configuration files live in `cloud-init/`.

#### a. Set cluster defaults

```bash
curl -X POST http://localhost:27777/admin/cluster-defaults \
  -H 'Content-Type: application/json' \
  -d @cloud-init/cluster-defaults.json
```

#### b. Create the compute group

The compute group cloud-config (`cloud-init/compute.yaml`) configures DNS,
auto-imports zypper GPG keys, and installs packages. Edit it to match your
environment before pushing.

```bash
CLOUD_CONFIG=$(base64 -w0 < cloud-init/compute.yaml)
curl -X POST http://localhost:27777/admin/groups \
  -H 'Content-Type: application/json' \
  -d "{\"name\": \"compute\", \"description\": \"Compute nodes\", \"data\": {}, \"file\": {\"content\": \"${CLOUD_CONFIG}\", \"encoding\": \"base64\"}}"
```

To update an existing group, use PUT instead of POST:

```bash
curl -X PUT http://localhost:27777/admin/groups/compute \
  -H 'Content-Type: application/json' \
  -d "{\"name\": \"compute\", \"description\": \"Compute nodes\", \"data\": {}, \"file\": {\"content\": \"${CLOUD_CONFIG}\", \"encoding\": \"base64\"}}"
```

#### c. Set per-node hostname

```bash
curl -X PUT http://localhost:27777/admin/instance-info/<XNAME> \
  -H 'Content-Type: application/json' \
  -d '{"local-hostname": "<HOSTNAME>", "hostname": "<HOSTNAME>"}'
```

#### d. Verify

Use the impersonation endpoint to see exactly what a node will receive:

```bash
curl -s http://localhost:27777/admin/impersonation/<XNAME>/meta-data
curl -s http://localhost:27777/admin/impersonation/<XNAME>/vendor-data
curl -s http://localhost:27777/admin/impersonation/<XNAME>/compute.yaml
```

### 11. Power management (PCS + Redfish)

PCS (Power Control Service) manages node power state through the BMC's Redfish
API. PCS uses a "fake vault" mode where BMC credentials are stored in the
secrets environment file rather than HashiCorp Vault.

#### a. BMC credentials

The PCS quadlet (`pcs.container`) ships with default fake-vault Redfish
credentials (`PCS_FAKE_VAULT_REDFISH_USER=openchami`,
`PCS_FAKE_VAULT_REDFISH_PASSWORD=openchami`). These are the credentials PCS uses
when talking to the BMC's Redfish API.

To change them, edit `/etc/containers/systemd/pcs.container` and update the
`Environment=PCS_FAKE_VAULT_REDFISH_*` lines, then restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart pcs.service
```

#### b. Register the BMC Redfish endpoint in SMD

Register the BMC with its management IP. The `ID` is the BMC xname (the node
xname without the trailing `nN`). `RediscoverOnUpdate` tells SMD to
automatically crawl the Redfish tree and populate ComponentEndpoints:

```bash
curl -skf -X POST https://localhost:27779/hsm/v2/Inventory/RedfishEndpoints \
  -H 'Content-Type: application/json' \
  -d '{
    "ID": "<BMC_XNAME>",
    "FQDN": "<BMC_IP>",
    "RediscoverOnUpdate": true,
    "User": "<BMC_USER>",
    "Password": "<BMC_PASSWORD>"
  }'
```

Example with `x1000c0s0b0` as the BMC xname:

```bash
curl -skf -X POST https://localhost:27779/hsm/v2/Inventory/RedfishEndpoints \
  -H 'Content-Type: application/json' \
  -d '{
    "ID": "x1000c0s0b0",
    "FQDN": "148.187.104.15",
    "RediscoverOnUpdate": true,
    "User": "openchami",
    "Password": "Openchami0!"
  }'
```

#### c. Wait for SMD discovery and verify

SMD discovers the BMC's Redfish tree asynchronously. Poll until
`LastDiscoveryStatus` shows `DiscoverOK`:

```bash
curl -sk https://localhost:27779/hsm/v2/Inventory/RedfishEndpoints/<BMC_XNAME> \
  | jq '.DiscoveryInfo'
```

Expected output:

```json
{
  "LastDiscoveryAttempt": "2026-03-30T14:28:52.416183Z",
  "LastDiscoveryStatus": "DiscoverOK",
  "RedfishVersion": "1.0.2"
}
```

If discovery fails with `HTTPsGetFailed`, check:

- **Credentials:** Test them directly against the BMC:
  `curl -sk -u '<USER>:<PASS>' https://<BMC_IP>/redfish/v1/Systems/`
- **Network:** Ensure the RHEL host can reach the BMC IP on port 443
- **Session auth:** Some BMCs (e.g. Lenovo XCC) only support session-based
  auth, not HTTP Basic Auth. SMD handles this automatically — a 401 on direct
  curl with `-u` doesn't necessarily mean discovery will fail.

Verify that SMD populated the node's ComponentEndpoint with Redfish actions:

```bash
curl -sk https://localhost:27779/hsm/v2/Inventory/ComponentEndpoints?id=<XNAME> | jq .
```

#### d. Verify PCS power status

PCS polls SMD every 30 seconds to refresh its internal component map. After
discovery completes, wait up to 60 seconds then query:

```bash
curl -s http://localhost:28007/v1/power-status?xname=<XNAME> | jq .
```

Expected output:

```json
{
  "status": [
    {
      "xname": "x1000c0s0b0n0",
      "powerState": "on",
      "managementState": "available",
      "supportedPowerTransitions": [
        "On", "Soft-Off", "Off", "Soft-Restart",
        "Force-Off", "Init", "Hard-Restart"
      ]
    }
  ]
}
```

If the response shows `"Component not found in component map."`, either
discovery hasn't completed or PCS hasn't polled yet. Check PCS logs:

```bash
journalctl -u pcs.service --no-pager -n 20
```

Common issues:

- **"Missing/empty creds"**: `PCS_FAKE_VAULT_REDFISH_USER` /
  `PCS_FAKE_VAULT_REDFISH_PASSWORD` are not set in `pcs.container`. The RPM
  ships with defaults; if you removed them, add them back and restart PCS.
- **Postgres connection refused on port 5432**: The PCS quadlet `Exec` line
  is not passing `--postgres-port 15432` correctly. Check that the command
  string is properly quoted in `pcs.container`.

#### e. Power operations

PCS exposes power transitions via POST to `/v1/transitions`. The response
includes a `transitionID` to track progress.

Supported transitions (tested against Lenovo XCC / Redfish v1.0.2):

| Transition | Status |
|------------|--------|
| On | OK |
| Soft-Off | OK |
| Off | NOT TESTED |
| Soft-Restart | NOT TESTED |
| Force-Off | NOT TESTED |
| Init | NOT TESTED |
| Hard-Restart | NOT TESTED |

**Graceful shutdown (Soft-Off):**

```bash
curl -s -X POST http://localhost:28007/v1/transitions \
  -H 'Content-Type: application/json' \
  -d '{"operation": "Soft-Off", "location": [{"xname": "<XNAME>"}]}' | jq .
```

**Power on:**

```bash
curl -s -X POST http://localhost:28007/v1/transitions \
  -H 'Content-Type: application/json' \
  -d '{"operation": "On", "location": [{"xname": "<XNAME>"}]}' | jq .
```

**Force power off:**

```bash
curl -s -X POST http://localhost:28007/v1/transitions \
  -H 'Content-Type: application/json' \
  -d '{"operation": "Force-Off", "location": [{"xname": "<XNAME>"}]}' | jq .
```

**Graceful restart (Soft-Restart):**

```bash
curl -s -X POST http://localhost:28007/v1/transitions \
  -H 'Content-Type: application/json' \
  -d '{"operation": "Soft-Restart", "location": [{"xname": "<XNAME>"}]}' | jq .
```

**Check transition status:**

```bash
curl -s http://localhost:28007/v1/transitions/<TRANSITION_ID> | jq .
```

The transition moves through `in-progress` → `completed`. The `tasks` array
shows per-node status:

```json
{
  "transitionID": "d4ea37c6-0f42-4b80-a9bf-ebea9ea1bfb6",
  "operation": "Soft-Off",
  "transitionStatus": "completed",
  "taskCounts": { "total": 1, "succeeded": 1, "failed": 0 },
  "tasks": [
    {
      "xname": "x1000c0s0b0n0",
      "taskStatus": "succeeded",
      "taskStatusDescription": "Transition confirmed, gracefulshutdown"
    }
  ]
}
```

### Updating a node

SMD and BSS data is stored in PostgreSQL and survives service restarts. However,
`bss-init` re-runs migrations on each RPM install, which resets the BSS database.
After an RPM reinstall, re-register boot parameters (step 7). SMD data persists.

### Troubleshooting

**DHCP: "failed to select a subnet for incoming packet"**

Kea's subnet doesn't match the interface the DHCP packet arrived on. The subnet
must cover the RHEL host's interface network, not the BMC management network.
Check `ip -4 addr show` and update `kea-dhcp4.conf` accordingly.

**TFTP timeout / iPXE not loading**

The TFTP server root (`/srv/tftp` in the container, `/etc/openchami/tftpboot` on
the host) is empty. Install `ipxe-bootimgs-x86` and copy the firmware files as
described in step 3.

**BSS returns chain URL with wrong IP**

BSS uses `BSS_ADVERTISE_ADDRESS` from `bss.container` to generate chain URLs. If
the boot script contains `192.168.100.1` or a wrong IP, update this environment
variable and restart BSS.

**kea-sync shows desired=0**

The node's IP (registered in SMD) doesn't fall within any Kea subnet. The IP in
SMD's EthernetInterface must be within the Kea `subnet4` range.

**Node gets IP but never fetches boot script**

The two-stage PXE chain requires TFTP. Check that: (1) iPXE binaries exist in
the TFTP root, (2) `next-server` in kea-dhcp4.conf points to the RHEL host IP,
(3) `boot-file-name` in the BIOS/UEFI client class matches the filename in TFTP,
(4) the firewall allows ports 69/udp, 80/tcp, and 27778/tcp (see step 3).

**Firewall blocking TFTP/HTTP after DHCP succeeds**

DHCP works even with the firewall up because Kea uses raw sockets. But TFTP
(port 69/udp) and HTTP (ports 80, 27778) are regular services and are blocked by
`firewalld` unless explicitly opened. The symptom is the node gets an IP from Kea
but times out trying to download iPXE. Run `sudo firewall-cmd --list-all` to
check, and see step 3 for the required rules.

## Architecture Notes

Architecture documentation and ADRs live under `docs/architecture/`:

- `docs/architecture/README.md`
- `docs/architecture/overview.md`
- `docs/architecture/compose-pxe-lab.md`
