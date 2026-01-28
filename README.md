# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM (or physical node) is network-booted using iPXE provided by a DHCP server. All services run within a Minikube cluster and are managed by a single Helm chart.

## Architecture Overview

This deployment implements the **HPC node lifecycle** for automatic node discovery and provisioning using **Kea DHCP**, a standalone **TFTP server**, and **OpenCHAMI services**.

### Boot Modes

1.  **Traditional PXE Boot** (for bare metal servers and standard VM firmware):
    ```
    Client Firmware (PXE ROM) → DHCP Request (Broadcast)
                                     ↓
    Kea DHCP responds with TFTP server IP + iPXE filename (undionly.kpxe / ipxe.efi)
                                     ↓
    Client downloads iPXE binary via TFTP (from ochami-tftp pod)
                                     ↓
    iPXE runs → sends another DHCP Request (identifies as iPXE client)
                                     ↓
    Kea DHCP responds with HTTP boot script URL
                                     ↓
    iPXE downloads boot.ipxe (from ochami-http-server) → loads kernel/initrd → boots
    ```

2.  **HTTP Boot** (for clients that already have iPXE loaded):
    ```
    iPXE Client → DHCP Request (identifies as iPXE)
                       ↓
    Kea DHCP responds with HTTP boot script URL directly
                       ↓
    iPXE downloads boot.ipxe → loads kernel/initrd → boots
    ```

### HPC Node Lifecycle & SMD Sync

The deployment replaces the legacy `coresmd` plugin with a **Sidecar Pattern**:

1.  **Kea DHCP**: Handles standard DHCP requests.
    *   **Unknown Nodes**: Assigned a dynamic IP from the pool (e.g., `192.168.100.100-200`).
    *   **Known Nodes**: Assigned a static IP reservation based on the Kea `hosts` database.
2.  **SMD Sync Sidecar**: A Python script running alongside Kea.
    *   Polls the **SMD** (State Management Database) for registered interfaces.
    *   Automatically creates/updates host reservations in Kea's PostgreSQL database.

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
│  │  Kea DHCP    │    │  Sidecar     │    │  Kea DHCP    │                   │
│  │  assigns     │    │  Syncs DB    │    │  assigns     │                   │
│  │  Dynamic IP  │    │  (Create     │    │  Static IP   │                   │
│  │  (Pool)      │    │   Reserv.)   │    │  (Reserv.)   │                   │
│  └──────────────┘    └──────────────┘    └──────────────┘                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

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

**Options:**
*   `--vms N`: Automatically create N test VMs (named `virtual-compute-node-0`, `virtual-compute-node-1`, etc.) after deployment.
*   `--rebuild`: Force a rebuild of the SLES image.
*   `--phy-iface IFACE`: Bridge a physical interface for bare-metal testing.

**What this script does:**
1.  **Checks & Installs Prerequisites**: Automatically installs `cri-dockerd`, CNI plugins, and other tools required for the Minikube `none` driver.
2.  **Builds SLES Image**: Builds a custom **openSUSE Leap 15.6 (SLES-based)** bootable image (kernel, initramfs, squashfs).
3.  **Starts Minikube**: Launches Minikube using the `none` driver directly on the host.
4.  **Configures Networking**:
    *   Sets up a local bridge (`virbr-pxe`) for local VM testing.
    *   Assigns IP `192.168.100.2` to the bridge.
5.  **Deploys OpenCHAMI**: Installs the Helm chart configured to serve artifacts via `192.168.100.2`.
    *   *Note: The script waits (up to 10m) for all services to be fully ready before proceeding to VM creation.*
6.  **Creates VMs (Optional)**: If `--vms` is specified, it creates the requested number of Libvirt VMs.

**Rebuilding Images:**
If you want to force a rebuild of the SLES image (e.g., after modifying the build script), run:
```bash
./deploy.sh --rebuild
```

## Step 1b: Deployment (Bare Metal Mode)

To boot physical machines, you can bridge a physical interface to the PXE network. This allows external devices to reach the DHCP and TFTP services running inside Minikube.

```bash
./deploy.sh --phy-iface eth1
```

*   `--phy-iface`: The physical interface on your host (e.g., `eth1`, `eno1`) to bridge to the PXE network.
    *   **Note:** The interface will be brought UP and attached to the `virbr-pxe` bridge. Any existing IP configuration on this interface effectively becomes secondary to the bridge configuration.
    *   **Warning:** Ensure this interface is connected to an isolated network switch. Do not connect it to a corporate LAN as it will serve DHCP.

If your host has `libvirt` installed, its `dnsmasq` service may conflict with Kea DHCP. Use the `--mode hardware` option to automatically stop and disable libvirt's default network and skip creating the `pxe-net` virtual network (since you are using a physical interface).
```bash
./deploy.sh --mode hardware --phy-iface eth1
```

You can also combine this with custom IP ranges if your physical network requires it:

```bash
./deploy.sh --phy-iface eth1 --ip 192.168.50.1 --cidr 24 \
            --dhcp-start 192.168.50.100 --dhcp-end 192.168.50.200
```

## Step 2: Verify the Deployment

Check that all the pods are running and the services are created.

```bash
minikube kubectl -- get pods -n ochami
minikube kubectl -- get services -n ochami
```
You should see pods for `ochami-kea`, `ochami-tftp`, `ochami-http-server`, `smd`, `bss`, and `postgres` running.

## Step 3: Create and Boot the VM (Local Mode)

### 3a. Create and Boot an Unknown Node (Discovery Mode)

When a VM is first created, its MAC address is not in SMD. Kea will assign it a dynamic IP from the configured pool:

1.  **Create the VM:**

    ```bash
    sudo ./scripts/create_vm.sh
    ```

2.  **Watch the discovery boot:**

    The VM will get a temporary IP (e.g., `192.168.100.100`) and boot the default image.
    
    Check Kea logs to see the lease assignment:
    ```bash
    minikube kubectl -- logs -n ochami ochami-kea -c kea-dhcp4
    ```

### 3b. Register the Node in SMD

To transition the node to production mode, you must register its MAC address in the State Management Database (SMD). The Sidecar will then sync this to Kea.

**Option 1: Automated Script (Recommended)**

We have provided a helper script to automate the registration process. It fetches the VM's MAC address and registers it with a specified IP. You can optionally specify a Component ID and Node ID (NID).

```bash
# Usage: ./scripts/register_local_vm.sh <vm-name> <desired-ip> [COMPONENT_ID] [NID]
./scripts/register_local_vm.sh virtual-compute-node 192.168.100.50

# Example with custom Component ID and NID:
# ./scripts/register_local_vm.sh virtual-compute-node-1 192.168.100.51 x0c0s0b0n1 2
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
```

### 3c. Boot the Production Node

After registration, wait a few seconds for the Sidecar to sync (default interval: 10s). Then restart the VM.

```bash
# Check sidecar logs to verify sync
minikube kubectl -- logs -n ochami ochami-kea -c sidecar

# Restart VM
sudo virsh destroy virtual-compute-node
sudo virsh start virtual-compute-node
```

The VM should now receive the production IP (`192.168.100.50`).

### 3d. Verify the Boot

```bash
# Ping the production IP
ping 192.168.100.50

# Check HTTP server logs for boot artifact downloads
minikube kubectl -- logs -n ochami ochami-http-server | tail -10
```

## 4. Booting Hardware Nodes

The process for physical hardware is similar.

### 4a. Connect Hardware
Ensure your hardware node is connected to the physical interface specified via `--phy-iface` (e.g., `eth1`).
*   **Warning:** Do not run this on a shared corporate network. Use an isolated switch or direct connection.
*   **Firewall:** Ensure your host firewall allows traffic on ports 67/udp, 69/udp, and 30080/tcp on the PXE interface.

### 4b. Register the Hardware Node
Locate the MAC address of your hardware node and register it using the hardware-specific script:

```bash
# Usage: ./scripts/register_hardware_node.sh <MAC_ADDRESS> <IP_ADDRESS> [COMPONENT_ID]
./scripts/register_hardware_node.sh 00:11:22:33:44:55 192.168.50.50 x1000c0s0b0n0
```

### 4c. Boot the Hardware
Power on the node. Once registered and synced, Kea will assign the static production IP and serve the boot image.

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

## Components Overview

| Component | Purpose |
| :--- | :--- |
| **Kea DHCP** | Main DHCP server. Assigns IPs and boot options (Next-Server, Boot-File). |
| **SMD Sync Sidecar** | Python script in Kea pod. Syncs SMD inventory to Kea's database for static reservations. |
| **TFTP Server** | Standalone pod (`ochami-tftp`). Serves iPXE binaries (`undionly.kpxe`, `ipxe.efi`). |
| **HTTP Server** | Serves `boot.ipxe` script, kernel, initramfs, and rootfs. |
| **SMD** | State Management Daemon - hardware inventory database. |
| **BSS** | Boot Script Service - provides dynamic boot scripts for known nodes. |
| **PostgreSQL** | Persistent storage for SMD, BSS, and Kea. |

## Troubleshooting

### VM doesn't get DHCP response
- Verify Kea pod is running: `kubectl get pods -n ochami`
- Check Kea logs: `kubectl logs -n ochami ochami-kea -c kea-dhcp4`
- Ensure the VM is on the `pxe-net` network: `virsh domiflist <vm-name>`
- **Important**: Kea must bind to the correct interface (`virbr-pxe`). Check logs for `listening on interface virbr-pxe`. If another DHCP server (like `dnsmasq` from `libvirt`'s default network) is running on the host, it may prevent Kea from binding to the port. Use the `--mode hardware` option during deployment to handle this.

### Node gets IP but fails TFTP
- Check TFTP pod status: `kubectl get pods -n ochami -l app.kubernetes.io/component=tftp`
- Verify TFTP service logs (if any, usually standard output/error).
- Ensure port 69/UDP is not blocked or used by another process on the host (e.g., `dnsmasq`).

### Node registered but still getting temporary IP
- Check Sidecar logs: `kubectl logs -n ochami ochami-kea -c sidecar`
- Verify the sync script found the interface in SMD and inserted it into Postgres.
- Verify node is in SMD: `curl http://<SMD_IP>:27779/hsm/v2/Inventory/EthernetInterfaces`

### iPXE loads but fails to download boot.ipxe
- Verify HTTP server is running: `kubectl logs -n ochami ochami-http-server`
- Test HTTP manually: `curl http://192.168.100.2:30080/boot.ipxe`

### Checking the full boot flow
```bash
# Watch DHCP logs
kubectl logs -n ochami ochami-kea -c kea-dhcp4 -f &

# Watch HTTP logs
kubectl logs -n ochami ochami-http-server -f &

# Start the VM
sudo virsh start virtual-compute-node
```