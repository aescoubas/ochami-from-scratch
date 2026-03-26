# Docker Compose PXE Lab

## Purpose

The Docker Compose lab provides a local OpenCHAMI PXE boot path that can be exercised
with libvirt VMs and validated from the guest serial console.

## Main Elements

- libvirt network: `ochami-pxe-net`
- libvirt bridge: `virbr-ochami`
- compose file: `deploy/compose/docker-compose.yml`
- config templates: `deploy/compose/configs/` (`envsubst` at deploy time for secrets)
- init scripts: `deploy/compose/pg-init/`
- boot artifacts: built by `scripts/ops/build-boot-artifacts.sh`

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

`TEST_NODE_IMAGE` selects the test-node payload for steps 6-8. Supported values
are `nixos` (default), `ubuntu`, `opensuse`, and `almalinux`.

"Prepare the PXE bridge" means:

- make sure `ochami-pxe-net` is attached to `virbr-ochami`
- temporarily pause conflicting libvirt DHCP networks if needed
- attach a dummy interface when necessary so the bridge reports carrier

## VM Boot Flow

1. A VM attached to `ochami-pxe-net` requests DHCP.
2. Kea assigns an address on `192.168.100.0/24`.
3. `kea-sync` reconciles the registered SMD node state into Kea reservations through
   Kea's native HTTP control API.
4. nginx serves the first-stage `/boot/v1/bootscript` iPXE entrypoint.
5. BSS resolves the registered MAC address to the OpenCHAMI node record and serves the
   second-stage bootscript.
6. nginx serves the selected image's kernel and initrd from `/artifacts/<image>/`.
7. The VM boots into the selected installer or netboot runtime and exposes a serial
   console that `create-test-vms.sh` validates with the image-specific readiness
   pattern.

## Operational Entry Points

- Deploy the stack:
  `make deploy METHOD=compose`
- Generate boot artifacts only:
  `make generate-images TEST_NODE_IMAGE=ubuntu`
- Create test VMs:
  `make create-test-vms COUNT=1 TEST_NODE_IMAGE=ubuntu`
- Inspect the first VM console:
  `sudo virsh --connect qemu:///system console ochami-test-node-0`
- Tear everything down:
  `make teardown METHOD=compose`

## Expected Success Signals

- `docker compose ... ps` shows healthy `smd`, `bss`, `kea`, `kea-sync`, `cloud-init`, and
  reachable `http-server`, `pcs`, and `tftp`
- `http://localhost/artifacts/<image>/...` returns `200` for the selected image
- `create-test-vms.sh` registers the VM MAC and starts the domain
- the guest console reaches the selected image's installer or runtime prompt
- for the `nixos` image, `/proc/cmdline` in the guest includes the OpenCHAMI-provided
  `xname`, `nid`, and `ds=nocloud-net` parameters
