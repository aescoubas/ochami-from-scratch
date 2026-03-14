# Docker Compose PXE Lab

## Purpose

The Docker Compose lab provides a local OpenCHAMI PXE boot path that can be exercised
with libvirt VMs and validated from the guest serial console.

## Main Elements

- libvirt network: `ochami-pxe-net`
- libvirt bridge: `virbr-ochami`
- compose runtime file: `ochami-docker-compose/docker-compose.generated.yml`
- rendered config directory: `ochami-docker-compose/configs/`
- generated boot artifact package: `nix build .#boot-artifacts`

## What Deploy Does

`scripts/ops/deploy.sh --method compose`:

1. checks dependencies
2. ensures the compose secrets file exists
3. builds and loads local OCI images
4. ensures the libvirt PXE network exists
5. prepares the PXE bridge so Kea can bind
6. generates the compose file and rendered configs from Nix
7. starts the compose stack and waits for health
8. registers default BSS boot parameters from `boot-artifacts`

"Prepare the PXE bridge" means:

- make sure `ochami-pxe-net` is attached to `virbr-ochami`
- temporarily pause conflicting libvirt DHCP networks if needed
- attach a dummy interface when necessary so the bridge reports carrier

## VM Boot Flow

1. A VM attached to `ochami-pxe-net` requests DHCP.
2. Kea assigns an address on `192.168.100.0/24`.
3. nginx serves the first-stage `/boot/v1/bootscript` iPXE entrypoint.
4. BSS resolves the registered MAC address to the OpenCHAMI node record and serves the
   second-stage bootscript.
5. nginx serves:
   - `/artifacts/opensuse/vmlinuz-lts`
   - `/artifacts/opensuse/initramfs-lts`
6. The VM boots into the NixOS netboot image and exposes a serial login shell.

## Operational Entry Points

- Deploy the stack:
  `make deploy METHOD=compose`
- Generate boot artifacts only:
  `make generate-images`
- Create test VMs:
  `make create-test-vms COUNT=1`
- Inspect the first VM console:
  `sudo virsh --connect qemu:///system console ochami-test-node-0`
- Tear everything down:
  `make teardown METHOD=compose`

## Expected Success Signals

- `docker compose ... ps` shows healthy `smd`, `bss`, `kea`, `cloud-init`, and
  reachable `http-server`, `pcs`, and `tftp`
- `http://localhost/artifacts/opensuse/vmlinuz-lts` returns `200`
- `create-test-vms.sh` registers the VM MAC and starts the domain
- the guest console reaches the `ochami-netboot` shell
- `/proc/cmdline` in the guest includes the OpenCHAMI-provided `xname`, `nid`, and
  `ds=nocloud-net` parameters
