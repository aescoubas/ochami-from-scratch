# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM (or physical node) is network-booted using iPXE provided by a DHCP server. All services run within a Minikube cluster and are managed by a single Helm chart.

## Architecture Overview

This deployment supports **two boot modes**:

1. **Traditional PXE Boot** (for bare metal servers and standard VM firmware):
   ```
   Client Firmware (PXE ROM) → DHCP Request
                                    ↓
   CoreDHCP responds with TFTP server + iPXE filename
                                    ↓
   Client downloads iPXE binary via TFTP (undionly.kpxe or ipxe.efi)
                                    ↓
   iPXE runs → sends another DHCP request (identifies as iPXE client)
                                    ↓
   CoreDHCP responds with HTTP boot script URL
                                    ↓
   iPXE downloads boot.ipxe → loads kernel/initrd via HTTP → boots
   ```

2. **HTTP Boot** (for clients that already have iPXE loaded):
   ```
   iPXE Client → DHCP Request (identifies as iPXE)
                      ↓
   CoreDHCP responds with HTTP boot script URL directly
                      ↓
   iPXE downloads boot.ipxe → loads kernel/initrd → boots
   ```

The **coresmd** plugin includes a built-in TFTP server with iPXE binaries for x86 (BIOS/UEFI) and ARM.

## 1. Prerequisites

*   **Minikube** with the **`none` (bare-metal)** driver.
    *   *Note: The deployment script will automatically install necessary system dependencies (like `conntrack`, `cri-dockerd`, `cri-tools`, and CNI plugins) for Debian/Ubuntu systems.*
*   [Helm](https://helm.sh/docs/intro/install/)
*   [Docker](https://docs.docker.com/get-docker/) (Required for building images and running the `none` driver)
*   Libvirt & `virt-install` (For local VM testing)
*   `sudo` privileges (Required for `none` driver networking and artifact cleanup)

## Step 1: Deployment (Local VM Mode)

Run the automated deployment script. This default mode sets up a local bridge (`virbr-pxe`) for testing with VMs.

```bash
./deploy.sh
```

**What this script does:**
1.  **Checks & Installs Prerequisites**: Automatically installs `cri-dockerd`, CNI plugins, and other tools required for the Minikube `none` driver.
2.  **Builds SLES Image**: Builds a custom **openSUSE Leap 15.6 (SLES-based)** bootable image (kernel, initramfs, squashfs).
3.  **Starts Minikube**: Launches Minikube using the `none` driver directly on the host.
4.  **Configures Networking**:
    *   Sets up a local bridge (`virbr-pxe`) for local VM testing.
    *   Assigns IP `192.168.100.2` to the bridge.
5.  **Deploys OpenCHAMI**: Installs the Helm chart configured to serve artifacts via `192.168.100.2`.

**Rebuilding Images:**
If you want to force a rebuild of the SLES image (e.g., after modifying the build script), run:
```bash
./deploy.sh --rebuild
```

## Step 1b: Deployment (Bare Metal Mode)

To boot physical machines, you must specify the physical interface connected to the client network.

```bash
./deploy.sh --interface eth1 --ip 192.168.50.1 --cidr 24 \
            --dhcp-start 192.168.50.100 --dhcp-end 192.168.50.200
```

*   `--interface`: The physical interface on your host (e.g., `eth1`, `eno1`).
*   `--ip`: The IP address to assign to this interface (acting as the server/gateway).
*   `--cidr`: The subnet mask in CIDR notation (default: 24).
*   `--dhcp-start` / `--dhcp-end`: The range of IPs to assign to booting clients.

## Step 2: Verify the Deployment

Check that all the pods are running and the services are created.

```bash
minikube kubectl -- get pods -n ochami
minikube kubectl -- get services -n ochami
```
You should see pods for `coredhcp`, `ochami-http-server`, `smd`, `bss`, and `postgres` running.

## Step 3: Create and Boot the VM (Local Mode)

1.  **Create the VM:**

    The `create_vm.sh` script uses `virt-install` to create a VM configured for PXE boot.

    ```bash
    # BIOS mode (default) - uses SeaBIOS with undionly.kpxe from TFTP
    sudo ./create_vm.sh

    # UEFI mode - uses OVMF firmware with ipxe.efi from TFTP
    sudo ./create_vm.sh --uefi

    # Custom VM settings
    sudo ./create_vm.sh --name my-compute-node --memory 4096 --vcpus 2 --uefi
    ```

    **Available options:**
    | Option | Description |
    | :--- | :--- |
    | `--name NAME` | VM name (default: virtual-compute-node) |
    | `--memory MiB` | Memory in MiB (default: 2048) |
    | `--vcpus N` | Number of vCPUs (default: 1) |
    | `--bios` | Use BIOS/Legacy boot mode (default) |
    | `--uefi` | Use UEFI boot mode |

    This will print the MAC address of the new VM and explain the boot flow.

2.  **Start the VM:**

    Start the VM and attach to its console to watch the boot process.

    ```bash
    sudo virsh start --console virtual-compute-node
    ```

3.  **Watch it Boot!**

    If everything is configured correctly, you should see the following in the VM's console:

    **BIOS Mode Boot Flow:**
    1. SeaBIOS PXE ROM sends DHCP request
    2. CoreDHCP responds with TFTP server address + `undionly.kpxe` filename
    3. PXE ROM downloads `undionly.kpxe` via TFTP
    4. iPXE sends another DHCP request (identifies itself as iPXE client)
    5. CoreDHCP responds with HTTP boot script URL
    6. iPXE downloads `boot.ipxe` and boots the kernel/initrd

    **UEFI Mode Boot Flow:**
    1. OVMF PXE driver sends DHCP request
    2. CoreDHCP responds with TFTP server address + `ipxe.efi` filename
    3. Firmware downloads `ipxe.efi` via TFTP
    4. iPXE sends another DHCP request (identifies itself as iPXE client)
    5. CoreDHCP responds with HTTP boot script URL
    6. iPXE downloads `boot.ipxe` and boots the kernel/initrd

## Cleanup

To remove the VM, Minikube cluster, network artifacts, and generated files, run:

```bash
./teardown.sh
```

**Available options:**
| Option | Description |
| :--- | :--- |
| `--remove-images` | Also delete Docker images and CNI plugins |
| `--vm-name NAME` | Specify VM name to remove (default: virtual-compute-node) |
| `-y, --yes` | Skip confirmation prompt |
| `-h, --help` | Show help |

**Examples:**
```bash
# Standard cleanup
./teardown.sh

# Full cleanup including Docker images
./teardown.sh --remove-images

# Remove a custom-named VM
./teardown.sh --vm-name my-compute-node

# Non-interactive cleanup (for scripts)
./teardown.sh -y --remove-images
```

This concludes the advanced tutorial. You have successfully booted a VM with a custom SLES image served entirely from within a Minikube cluster managed by a single Helm chart.

## Components Overview

| Component | Purpose |
| :--- | :--- |
| **CoreDHCP (coresmd)** | DHCP server with coresmd/bootloop plugins for PXE boot. Includes **built-in TFTP server** with iPXE binaries (undionly.kpxe, ipxe.efi) for BIOS and UEFI boot. |
| **HTTP Server** | Serves boot.ipxe script, kernel, initramfs, and rootfs |
| **SMD** | State Management Daemon - hardware inventory database |
| **BSS** | Boot Script Service - provides boot scripts for known nodes |
| **PostgreSQL** | Persistent storage for SMD and BSS |

## Networking & Driver Challenges

This section explains the networking complexities involved when using different Minikube drivers or attempting to boot physical hardware.

### The Core Issue: Layer 2 Visibility

DHCP relies on broadcast packets (`DHCPDISCOVER`), which are not routed. The DHCP server (pod) and the client (VM or physical machine) must be on the same network segment (broadcast domain).

### Network Services and Ports

| Service | Port | Protocol | Purpose |
| :--- | :--- | :--- | :--- |
| CoreDHCP | 67 | UDP | DHCP server (broadcast) |
| TFTP (built into coresmd) | 69 | UDP | Serves iPXE binaries to PXE clients |
| HTTP | 30080 | TCP | Serves boot.ipxe, kernel, initramfs, rootfs |
| SMD | 27779 | TCP | Hardware inventory API (internal) |
| BSS | 27778 | TCP | Boot script service API (internal) |

### Driver Compatibility Matrix

| Driver | Pod Location | Client Location | Status | Explanation |
| :--- | :--- | :--- | :--- | :--- |
| **`none`** | Host OS | Host Bridge | **Works** | The pod shares the Host OS network namespace, allowing it to bind directly to the Host Bridge (`virbr-pxe`) and receive broadcasts. |
| **`docker`** | Container | Host Bridge | **Fail** | The pod runs inside an isolated Docker container on a separate bridge. It cannot see broadcast traffic from the Host Bridge without complex, non-standard bridging. |
| **`kvm2` / `libvirt`** | Minikube VM | Host Bridge | **Conditional** | Fails by default because the Minikube VM is on a separate NAT network. **Works** only if you attach a secondary interface to the Minikube VM that is bridged to the Host Bridge (handled by `setup_minikube_net.sh`). |
| **Bare Metal** | (Any) | Physical Wire | **Fail** | Fails by default. The internal Host Bridge (`virbr-pxe`) is isolated from your physical Ethernet port. To work, you must bridge your physical NIC (e.g., `eth0`) to `virbr-pxe`, effectively turning your workstation into a switch. |

### Boot Artifacts

**iPXE binaries** (built into coresmd, served via TFTP):
| File | Purpose |
| :--- | :--- |
| `undionly.kpxe` | iPXE for BIOS/Legacy PXE boot |
| `ipxe.efi` | iPXE for UEFI PXE boot |

**Boot files** (built into http-server image, served via HTTP from `ochami-helm/http-server/artifacts/`):
| File | Purpose |
| :--- | :--- |
| `vmlinuz-lts` | Linux kernel |
| `initramfs-lts` | Initial ramdisk |
| `rootfs.squashfs` | Root filesystem (squashfs live image) |

### Summary
*   **For Development/Testing:** The **`none`** driver is the most reliable method for this setup as it removes the network isolation layers between the pod and the host's virtual bridge.
*   **For Bare Metal:** Use the `--interface` flag in `deploy.sh` to target your physical network interface directly, ensuring the containerized DHCP server (running in host network mode) can see the physical network broadcasts.

## Troubleshooting

### VM doesn't get DHCP response
- Verify CoreDHCP pod is running: `kubectl get pods -n ochami`
- Check CoreDHCP logs: `kubectl logs -n ochami ochami-coredhcp`
- Ensure the VM is on the `pxe-net` network: `virsh domiflist <vm-name>`

### VM gets DHCP but fails to download iPXE
- Check CoreDHCP logs for TFTP errors: `kubectl logs -n ochami ochami-coredhcp`
- The TFTP server is built into coresmd - iPXE binaries are bundled in the image
- Test TFTP manually: `tftp 192.168.100.2 -c get undionly.kpxe`

### iPXE loads but fails to download boot.ipxe
- Verify HTTP server is running: `kubectl logs -n ochami ochami-http-server`
- Test HTTP manually: `curl http://192.168.100.2:30080/boot.ipxe`
- Check boot script content: `kubectl get configmap -n ochami ochami-http-server-content -o yaml`

### Kernel fails to boot
- Verify kernel and initramfs exist in artifacts directory
- Check the boot.ipxe script URLs are correct
- Try loading kernel manually in iPXE: `kernel http://192.168.100.2:30080/artifacts/vmlinuz-lts`