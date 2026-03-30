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

Install on AlmaLinux / RHEL / Fedora:

```bash
sudo dnf install ./openchami-*.noarch.rpm
```

The RPM `%post` scriptlet runs `bootstrap.sh` which creates
`/etc/openchami/artifacts/`, generates random database passwords in
`/etc/openchami/openchami.env`, and reloads systemd.

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
scp openchami-0.1.0-1.noarch.rpm <rhel-host>:~/
```

On the RHEL host:

```bash
sudo dnf install -y ~/openchami-*.noarch.rpm
```

If upgrading from a previous package name (`ochami-from-scratch`), remove it
first: `sudo dnf remove ochami-from-scratch`.

The `%post` scriptlet creates `/etc/openchami/artifacts/`, generates random
database passwords in `/etc/openchami/openchami.env`, and reloads systemd.

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

### 3. Open firewall ports

RHEL/AlmaLinux enables `firewalld` by default. The PXE boot chain requires
several ports to be reachable from the node. Without these, the node gets a DHCP
lease (Kea uses raw sockets that bypass the firewall) but cannot TFTP-download
iPXE or reach any HTTP service — causing a silent timeout after DHCP.

```bash
sudo firewall-cmd --add-service=tftp --permanent        # TFTP (port 69/udp, iPXE firmware)
sudo firewall-cmd --add-port=69/udp --permanent          # explicit UDP rule for TFTP data
sudo firewall-cmd --add-port=80/tcp --permanent           # HTTP (nginx: kernel, initrd, boot.ipxe)
sudo firewall-cmd --add-port=27777/tcp --permanent        # cloud-init metadata service
sudo firewall-cmd --add-port=27778/tcp --permanent        # BSS (boot script service)
sudo firewall-cmd --add-port=27779/tcp --permanent        # SMD (state management database)
sudo firewall-cmd --reload
```

Verify:

```bash
sudo firewall-cmd --list-all
# Should show: services: ... tftp
# Should show: ports: 69/udp 80/tcp 27777/tcp 27778/tcp 27779/tcp
```

### 4. Install iPXE boot firmware

The TFTP server ships with an empty root directory. PXE-booting nodes need iPXE
firmware (`ipxe.efi` for UEFI, `undionly.kpxe` for legacy BIOS) to chainload
into the BSS boot script. Install iPXE and copy the binaries:

```bash
sudo dnf install -y ipxe-bootimgs-x86
sudo mkdir -p /etc/openchami/tftpboot
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
[openchami-image-building](../../operations/openchami-image-building) repository,
which produces a minimal openSUSE Leap 15.6 system as a compressed cpio archive.

On your build machine (requires `mkosi` and `zstd`):

```bash
cd operations/openchami-image-building

# Build the openSUSE Leap cpio image
make build-leap-live

# Push to the RHEL host and register BSS boot parameters
make push HOST=<RHEL_HOST> MAC=<PXE_MAC>
```

Or push manually:

```bash
SSH_USER=root ./scripts/push-to-openchami.sh <RHEL_HOST> <PXE_MAC>
```

This pushes two files to `/etc/openchami/artifacts/opensuse/` on the server:

```text
/etc/openchami/artifacts/opensuse/
├── vmlinuz                       (14 MB, kernel)
└── opensuse-leap-live.cpio.zst   (190 MB, compressed rootfs)
```

Verify they are served:

```bash
curl -sf -o /dev/null -w "%{http_code}" http://localhost:80/artifacts/opensuse/vmlinuz
# Should return 200
curl -sf -o /dev/null -w "%{http_code}" http://localhost:80/artifacts/opensuse/opensuse-leap-live.cpio.zst
# Should return 200
```

The image boots directly into RAM — the kernel unpacks the cpio as the root
filesystem with systemd as init. No dracut, no squashfs, no network fetch
during boot. Default root password: `openchami`.

### 6. Register the node in SMD

Register the node's **PXE NIC** ethernet interface (MAC + IP) and component.

**Important:** Use the MAC address of the node's PXE NIC, not the BMC MAC. The
BMC typically has a static IP on a management network and is not involved in PXE
boot. The PXE NIC MAC is what appears in DHCP DISCOVER packets — check Kea logs
(`journalctl -u kea.service`) if unsure which MAC the node is using.

The IP address must fall within the Kea DHCP subnet configured in step 8 so that
kea-sync can create a DHCP reservation. It should be on the same L2 network as
the RHEL host's interface.

Replace `<XNAME>`, `<PXE_MAC>`, and `<NODE_IP>` with your values:

```bash
# Register the ethernet interface
curl -skf -X POST https://localhost:27779/hsm/v2/Inventory/EthernetInterfaces \
  -H 'Content-Type: application/json' \
  -d '{
    "ComponentID": "<XNAME>",
    "Description": "PXE NIC",
    "MACAddress": "<PXE_MAC>",
    "IPAddresses": [{"IPAddress": "<NODE_IP>", "Network": "HMN"}]
  }'

# Register the component
curl -skf -X POST https://localhost:27779/hsm/v2/State/Components \
  -H 'Content-Type: application/json' \
  -d '{
    "Components": [{
      "ID": "<XNAME>",
      "State": "Ready",
      "NetType": "Sling",
      "Arch": "X86",
      "Role": "Compute"
    }]
  }'
```

Verify:

```bash
curl -kfs https://localhost:27779/hsm/v2/State/Components/<XNAME> | jq .
curl -kfs https://localhost:27779/hsm/v2/Inventory/EthernetInterfaces | jq .
```

### 7. Register boot parameters in BSS

If you used `make push` in step 5, BSS is already configured. Otherwise,
register manually. Replace `<SERVER_IP>` with the RHEL host's IP and `<PXE_MAC>`
with the PXE NIC MAC:

```bash
curl -sf -X PUT http://localhost:27778/boot/v1/bootparameters \
  -H 'Content-Type: application/json' \
  -d '{
    "macs": ["<PXE_MAC>"],
    "kernel": "http://<SERVER_IP>:80/artifacts/opensuse/vmlinuz",
    "initrd": "http://<SERVER_IP>:80/artifacts/opensuse/opensuse-leap-live.cpio.zst",
    "params": "ip=dhcp console=ttyS0,115200n8 console=tty0"
  }'
```

iPXE downloads the kernel and the cpio archive (as initrd). The kernel unpacks
the cpio directly into RAM and boots systemd — no intermediate dracut or
network fetch step.

Verify the boot script BSS will serve to this MAC:

```bash
curl -sf "http://localhost:27778/boot/v1/bootscript?mac=<PXE_MAC>&arch=x86_64"
```

This should return an iPXE script with `kernel` and `initrd` lines pointing to
your server.

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
8. iPXE downloads kernel (14 MB) + cpio rootfs (190 MB) over HTTP
9. Kernel unpacks the cpio into RAM, finds /init (systemd)
10. systemd starts → live openSUSE Leap system running entirely in RAM
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



