# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM (or physical node) is network-booted using iPXE provided by a DHCP server. All services run within a Minikube cluster and are managed by a single Helm chart.

## Architecture Overview

This deployment supports **two boot modes** and implements the **HPC node lifecycle** for automatic node discovery and provisioning.

### Boot Modes

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

### HPC Node Lifecycle

The deployment implements automatic node discovery using a two-plugin architecture:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          HPC Node Lifecycle                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │  UNKNOWN     │    │  DISCOVERED  │    │  PRODUCTION  │                   │
│  │  Hardware    │───▶│  (in SMD)    │───▶│  Boot        │                   │
│  └──────────────┘    └──────────────┘    └──────────────┘                   │
│         │                   │                   │                            │
│         ▼                   ▼                   ▼                            │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │  bootloop    │    │  NAK sent    │    │  coresmd     │                   │
│  │  assigns     │    │  to force    │    │  assigns     │                   │
│  │  temp IP     │    │  re-handshake│    │  production  │                   │
│  │  (5m lease)  │    │              │    │  IP (1h)     │                   │
│  └──────────────┘    └──────────────┘    └──────────────┘                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Stage | Plugin | IP Source | Lease | Purpose |
|-------|--------|-----------|-------|---------|
| **Unknown** | bootloop | Temporary pool (192.168.100.100-200) | 5 min | Node boots discovery image to register with SMD |
| **Transition** | bootloop | N/A (NAK) | N/A | Forces re-handshake when node becomes known |
| **Production** | coresmd | SMD inventory | 1 hour | Production IP and boot parameters |

**Why the NAK is critical:**
When a node with a temporary lease is registered in SMD, the bootloop plugin detects this state change and sends a DHCPNAK. This forces the node to restart the DHCP handshake, where coresmd now recognizes it and assigns the production IP.

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

### 3a. Create and Boot an Unknown Node (Discovery Mode)

When a VM is first created, its MAC address is not in SMD. The bootloop plugin handles it:

1.  **Create the VM:**

    ```bash
    sudo ./create_vm.sh
    ```

2.  **Watch the discovery boot:**

    The VM will get a temporary IP from the bootloop pool and receive a "default" (reboot) iPXE script. This is the discovery mode - the node keeps rebooting until registered.

    Check CoreDHCP logs to see bootloop handling the unknown MAC:
    ```bash
    minikube kubectl -- logs -n ochami ochami-coredhcp | grep bootloop
    ```

### 3b. Register the Node in SMD

To transition the node to production mode, you must register its MAC address in the State Management Database (SMD).

**Option 1: Automated Script (Recommended)**

We have provided a helper script to automate the registration process. It fetches the VM's MAC address and registers it with a specified IP.

```bash
# Usage: ./register_local_vm.sh <vm-name> <desired-ip>
./register_local_vm.sh virtual-compute-node 192.168.100.50
```

**Option 2: Manual Registration (Details)**

If you prefer to understand the underlying API calls, you can perform the registration manually:

```bash
# 1. Get the VM's MAC address
MAC=$(sudo virsh domiflist virtual-compute-node | grep virbr-pxe | awk '{print $5}')
echo "VM MAC: $MAC"

# 2. Get SMD service IP
SMD_IP=$(minikube kubectl -- get svc ochami-smd -n ochami -o jsonpath='{.spec.clusterIP}')

# 3. Add node component to SMD
curl -X POST http://${SMD_IP}:27779/hsm/v2/State/Components \
  -H "Content-Type: application/json" \
  -d '{
    "Components": [{
      "ID": "x0c0s0b0n0",
      "Type": "Node",
      "State": "On",
      "Flag": "OK",
      "Role": "Compute",
      "NID": 1,
      "NetType": "Sling"
    }]
  }'

# 4. Add EthernetInterface linking MAC to production IP
curl -X POST http://${SMD_IP}:27779/hsm/v2/Inventory/EthernetInterfaces \
  -H "Content-Type: application/json" \
  -d "{
    \"Description\": \"Node NIC\",
    \"MACAddress\": \"${MAC}\",
    \"IPAddresses\": [{\"IPAddress\": \"192.168.100.50\"}],
    \"ComponentID\": \"x0c0s0b0n0\"
  }"

# 5. Verify registration
curl -s http://${SMD_IP}:27779/hsm/v2/Inventory/EthernetInterfaces | python3 -m json.tool
```

### 3c. Boot the Production Node

After registration, restart the VM. The coresmd plugin will now handle it:

```bash
sudo virsh destroy virtual-compute-node
sudo virsh start virtual-compute-node
```

Watch the CoreDHCP logs to see coresmd assign the production IP:
```bash
minikube kubectl -- logs -n ochami ochami-coredhcp | grep coresmd
```

You should see:
```
assigning 192.168.100.50 to <MAC> (Node) with a lease duration of 1h0m0s
```

### 3d. Verify the Boot

```bash
# Ping the production IP
ping 192.168.100.50

# Check HTTP server logs for boot artifact downloads
minikube kubectl -- logs -n ochami ochami-http-server | tail -10
```

### VM Creation Options

| Option | Description |
| :--- | :--- |
| `--name NAME` | VM name (default: virtual-compute-node) |
| `--memory MiB` | Memory in MiB (default: 2048) |
| `--vcpus N` | Number of vCPUs (default: 1) |
| `--bios` | Use BIOS/Legacy boot mode (default) |
| `--uefi` | Use UEFI boot mode |

## 4. Booting Hardware Nodes

The process for physical hardware is slightly different. Unlike local VMs, which you can easily "discover" by letting them bootloop, **hardware nodes must be registered BEFORE they can successfully boot the OS.**

If you boot an unregistered hardware node, it will enter **Discovery Mode**: it will receive a temporary IP, download a default script, and reboot (or hang). It will **not** boot the OS.

### 4a. Connect Hardware
Ensure your hardware node is connected to the interface specified during deployment (e.g., `eth1`).
*   **Warning:** Do not run this on a shared corporate network. Use an isolated switch or direct connection.
*   **Firewall:** Ensure your host firewall allows traffic on ports 67/udp, 69/udp, and 30080/tcp on the PXE interface.

### 4b. Register the Hardware Node
Locate the MAC address of your hardware node (sticker or BIOS) and register it using the hardware-specific script:

```bash
# Usage: ./register_hardware_node.sh <MAC_ADDRESS> <IP_ADDRESS> [COMPONENT_ID]
./register_hardware_node.sh 00:11:22:33:44:55 192.168.50.50 x1000c0s0b0n0
```
*   `MAC_ADDRESS`: The physical MAC address of the node's NIC.
*   `IP_ADDRESS`: The static IP you want to assign to this node (must be within the range defined in `deploy.sh`).
*   `COMPONENT_ID` (Optional): A unique ID for the node (default: `x1000c0s0b0n0`).

### 4c. Boot the Hardware
Power on the node. Since it is now registered in SMD, the `coresmd` plugin will recognize it and serve the boot image immediately.

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

## Components Overview

| Component | Purpose |
| :--- | :--- |
| **CoreDHCP** | DHCP server with coresmd and bootloop plugins |
| **coresmd plugin** | Handles **known** nodes from SMD. Assigns production IPs, serves boot scripts. Includes **built-in TFTP server** with iPXE binaries. |
| **bootloop plugin** | Handles **unknown** nodes. Assigns temporary IPs for discovery. Sends NAK when node becomes known to trigger re-handshake. |
| **HTTP Server** | Serves boot.ipxe script, kernel, initramfs, and rootfs |
| **SMD** | State Management Daemon - hardware inventory database |
| **BSS** | Boot Script Service - provides dynamic boot scripts for known nodes |
| **PostgreSQL** | Persistent storage for SMD and BSS |

### CoreDHCP Plugin Chain

The plugins are processed in order:

```yaml
plugins:
  - server_id: "192.168.100.2"      # DHCP server identity
  - dns: "8.8.8.8"                   # DNS server for clients
  - router: "192.168.100.2"          # Default gateway
  - netmask: "255.255.255.0"         # Subnet mask

  # coresmd - FIRST: Check if MAC is in SMD
  - coresmd: <smd_url> <boot_script_url> "" 30s 1h true

  # bootloop - SECOND: Catch-all for unknown MACs
  - bootloop: /tmp/coredhcp.db default 5m 192.168.100.100 192.168.100.200
```

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

### Unknown node keeps rebooting (expected behavior)
- This is the discovery mode - bootloop sends a "default" reboot script
- Register the node in SMD to transition to production mode (see Step 3b)

### Node registered but still getting temporary IP
- Wait for coresmd cache to refresh (every 30 seconds)
- Check cache status in logs: `kubectl logs -n ochami ochami-coredhcp | grep "Cache updated"`
- Verify node is in SMD: `curl http://<SMD_IP>:27779/hsm/v2/Inventory/EthernetInterfaces`

### VM gets DHCP but fails to download iPXE
- Check CoreDHCP logs for TFTP errors: `kubectl logs -n ochami ochami-coredhcp`
- The TFTP server is built into coresmd - iPXE binaries are bundled in the image
- Test TFTP manually: `tftp 192.168.100.2 -c get undionly.kpxe`

### iPXE loads but fails to download boot.ipxe
- Verify HTTP server is running: `kubectl logs -n ochami ochami-http-server`
- Test HTTP manually: `curl http://192.168.100.2:30080/boot.ipxe`
- Check boot script content: `kubectl get configmap -n ochami ochami-http-server-content -o yaml`

### Kernel fails to boot or rootfs not downloaded
- Verify kernel and initramfs exist in artifacts directory
- Check the boot.ipxe script URLs are correct
- Check HTTP server logs for rootfs.squashfs requests
- Ensure the kernel got DHCP (no NAKs during boot): check CoreDHCP logs

### Checking the full boot flow
```bash
# Watch all logs in real-time
kubectl logs -n ochami ochami-coredhcp -f &
kubectl logs -n ochami ochami-http-server -f &

# Start the VM
sudo virsh start virtual-compute-node

# Expected sequence:
# 1. coresmd/bootloop: IP assignment
# 2. HTTP: boot.ipxe download
# 3. HTTP: vmlinuz-lts download
# 4. HTTP: initramfs-lts download
# 5. HTTP: rootfs.squashfs download (from kernel/dracut)
```
