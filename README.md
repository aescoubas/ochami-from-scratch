# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM (or physical node) is network-booted using iPXE provided by a DHCP server. Services can be deployed using either **Minikube** (Kubernetes), **Quadlets** (systemd-managed Podman containers), or **Docker Compose**.

## Quick Start (Quadlets)

Deploy OpenCHAMI with Quadlets and create a test VM in one command:

```bash
./deploy.sh --method quadlets --vms 1
```

Verify the deployment:
```bash
# Check services are running
sudo podman ps

# Check VM booted successfully (wait ~30 seconds after deploy)
ping -c 3 192.168.100.100

# View boot logs
sudo podman logs ochami-http-server-http-server | grep -E "(vmlinuz|rootfs)"
```

For detailed instructions, see the sections below.

---

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

### For Minikube Deployment
*   **Minikube** with the **`none` (bare-metal)** driver.
    *   *Note: The deployment script will automatically install necessary system dependencies (like `conntrack`, `cri-dockerd`, `cri-tools`, and CNI plugins) for Debian/Ubuntu systems.*
*   [Helm](https://helm.sh/docs/intro/install/)
*   [Docker](https://docs.docker.com/get-docker/) (Required for building images and running the `none` driver)

### For Quadlets Deployment
*   **Podman** (version 4.0+)
*   [Helm](https://helm.sh/docs/intro/install/) (Used to template the Kubernetes YAML)
*   *Note: Quadlets deployment uses systemd integration with `podman kube play`*

### Common Requirements
*   Libvirt & `virt-install` (For local VM testing)
*   `sudo` privileges (Required for networking and container management)

## Step 1: Deployment

### Option A: Minikube Deployment (Default)

Run the automated deployment script with Minikube (Kubernetes). This is the default mode.

```bash
./deploy.sh
```

Or explicitly:
```bash
./deploy.sh --method minikube
```

### Option B: Quadlets Deployment (Recommended for simplicity)

Deploy using Podman Quadlets, which runs containers as systemd services with host networking:

```bash
./deploy.sh --method quadlets
```

To deploy with test VMs:
```bash
./deploy.sh --method quadlets --vms 1
```

**Common Options:**
*   `--method [minikube|quadlets|docker-compose]`: Choose the deployment method (default: minikube)
*   `--vms N`: Automatically create N test VMs (named `virtual-compute-node-0`, `virtual-compute-node-1`, etc.)
*   `--rebuild`: Force a rebuild of container images
*   `--phy-iface IFACE`: Bridge a physical interface for bare-metal testing
*   `--ip ADDRESS`: Set the PXE server IP (default: 192.168.100.2)
*   `--cidr CIDR`: Set the network CIDR (default: 24)

### What the deployment script does:

| Step | Minikube | Quadlets |
|------|----------|----------|
| 1. Prerequisites | Installs cri-dockerd, CNI plugins | Checks for podman, helm |
| 2. Build Images | Builds with Docker, loads into Minikube | Builds with Podman |
| 3. Start Orchestrator | Starts Minikube with `none` driver | N/A (uses systemd) |
| 4. Configure Network | Creates `virbr-pxe` bridge, assigns 192.168.100.2 | Same |
| 5. Deploy Services | Helm install to Kubernetes | Helm template → Quadlet YAML |
| 6. Create VMs | Creates Libvirt VMs if `--vms` specified | Same |

### Key Differences Between Methods

| Feature | Minikube | Quadlets |
|---------|----------|----------|
| Boot Script | BSS dynamic (per-node) | Static boot.ipxe (all nodes same) |
| Service Discovery | Kubernetes DNS | Host networking (localhost) |
| StatefulSets | Supported | Limited support |
| Redfish Emulator | Works | Does not start (StatefulSet issue) |
| Management | `kubectl` commands | `systemctl` + `podman` commands |

**Rebuilding Images:**
```bash
./deploy.sh --method quadlets --rebuild
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

### For Minikube

Check that all the pods are running and the services are created.

```bash
minikube kubectl -- get pods -n ochami
minikube kubectl -- get services -n ochami
```

You should see pods for `ochami-kea`, `ochami-tftp`, `ochami-http-server`, `smd`, `bss`, and `postgres` running.

### For Quadlets

Check the systemd service and running containers:

```bash
# Check systemd service status
sudo systemctl status ochami

# List running containers
sudo podman ps

# Expected containers:
# - localhost-postgres
# - ochami-smd-smd
# - ochami-bss-bss
# - ochami-http-server-http-server
# - ochami-kea-kea-dhcp4
# - ochami-kea-sidecar
# - ochami-tftp-tftp
```

### Verify Services are Responding

Test that the core services are accessible:

```bash
# Check SMD is ready
curl -s http://localhost:27779/hsm/v2/service/ready
# Expected: {"code":0,"message":"HSM is healthy"}

# Check BSS is ready
curl -s http://localhost:27778/boot/v1/service/status
# Expected: {"status":"running"}

# Check HTTP server is serving boot artifacts
curl -s -I http://localhost:80/boot.ipxe
# Expected: HTTP/1.1 200 OK

# Check TFTP is listening (from another machine or VM)
# tftp 192.168.100.2 -c get undionly.kpxe
```

### Verify Boot Script Content

```bash
# For Quadlets (static boot script):
curl -s http://localhost:80/boot.ipxe
# Should show iPXE script with kernel, initrd, and boot commands

# For Minikube (BSS dynamic):
curl -s "http://localhost:80/boot/v1/bootscript?mac=00:00:00:00:00:00"
# Should return a boot script (may be a chain script for unknown MACs)
```

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

We have provided a helper script to automate the registration process. It:
1.  Fetches the VM's MAC address.
2.  Registers the Node Component (with IP) in SMD.
3.  **Registers the Redfish Endpoint (BMC)** in SMD (linking it to the Emulator).
4.  Registers Boot Parameters in BSS.

```bash
# Usage: ./scripts/register_local_vm.sh <vm-name> <desired-ip> [COMPONENT_ID] [NID]
./scripts/register_local_vm.sh virtual-compute-node-0 192.168.100.50

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
# Ping the VM (it will get an IP from DHCP pool, typically 192.168.100.100+)
ping 192.168.100.100

# Or ping the registered static IP if configured
ping 192.168.100.50
```

**For Minikube:**
```bash
# Check HTTP server logs for boot artifact downloads
minikube kubectl -- logs -n ochami ochami-http-server | tail -10
```

**For Quadlets:**
```bash
# Check HTTP server logs
sudo podman logs ochami-http-server-http-server | tail -10

# You should see requests for:
# - /boot.ipxe (or /boot/v1/bootscript for Minikube)
# - /artifacts/vmlinuz-lts
# - /artifacts/initramfs-lts
# - /artifacts/rootfs.squashfs
```

### 3e. Full Boot Verification Checklist

Run these commands to verify a successful boot:

```bash
# 1. Check VM is running
sudo virsh domstate virtual-compute-node-0

# 2. Check DHCP lease was issued (Quadlets)
sudo podman logs ochami-kea-kea-dhcp4 2>&1 | grep -i "lease"

# 3. Check boot artifacts were downloaded (Quadlets)
sudo podman logs ochami-http-server-http-server 2>&1 | grep -E "(vmlinuz|initramfs|rootfs)"

# 4. Verify VM is reachable
ping -c 3 192.168.100.100

# 5. (Optional) SSH to VM if configured
ssh local@192.168.100.100  # password: linux
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

### Using the Teardown Script

To remove the VM, cluster/services, network artifacts, and generated files:

```bash
./teardown.sh
```

**Available options:**
| Option | Description |
| :--- | :--- |
| `--remove-images` | Also delete Docker/Podman images and CNI plugins |
| `--vm-name NAME` | Specify VM name to remove (default: virtual-compute-node) |
| `-y, --yes` | Skip confirmation prompt |
| `-h, --help` | Show help |

### Manual Cleanup (Quadlets)

If you need to manually clean up a Quadlets deployment:

```bash
# Stop and remove VMs
sudo virsh destroy virtual-compute-node-0
sudo virsh undefine virtual-compute-node-0

# Stop the ochami service
sudo systemctl stop ochami

# Remove Quadlet files
sudo rm -f /etc/containers/systemd/ochami.yaml
sudo rm -f /etc/containers/systemd/ochami.kube
sudo systemctl daemon-reload

# Remove all pods/containers
sudo podman pod rm -f -a

# Clean up libvirt network
virsh net-destroy pxe-net
virsh net-undefine pxe-net

# Remove network interface
sudo ip link delete ochami-dummy 2>/dev/null || true
```

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
| **Redfish Emulator** | Lightweight emulator (StatefulSet) that controls VM power (On/Off/Reboot) via Libvirt, exposing a Redfish API. |

## 5. Using the Redfish Emulator

The deployment includes an optional **Redfish Emulator** that mimics a Baseboard Management Controller (BMC) for each VM. This allows you to control the VM's power state (On, Off, Reboot) via standard Redfish API calls.

### 5a. Enable the Emulator
The emulator is automatically enabled when you deploy with VMs using the `--vms` flag:

```bash
./deploy.sh --vms 1
```

This creates:
1.  A VM named `virtual-compute-node-0`.
2.  A corresponding emulator pod `ochami-redfish-emulator-0`.

### 5b. Controlling the VM (Power/Reboot)

We provide a helper script to interact with the Redfish emulator. This script automatically handles port forwarding and sends the appropriate Redfish commands.

**Usage:**
```bash
# Reboot VM 0 (Default)
./scripts/redfish_power_control.sh 0 reboot

# Power Off VM 0
./scripts/redfish_power_control.sh 0 stop

# Power On VM 0
./scripts/redfish_power_control.sh 0 start
```

### 5c. Verifying Functionality

You can verify the emulator works by sending a reboot command and watching the VM status.

1.  **Stop the VM:**
    ```bash
    ./scripts/redfish_power_control.sh 0 stop
    ```

2.  **Verify it stopped:**
    ```bash
    sudo virsh domstate virtual-compute-node-0
    # Output should be: shut off
    ```

3.  **Start the VM:**
    ```bash
    ./scripts/redfish_power_control.sh 0 start
    ```

## Troubleshooting

### General Issues

#### VM doesn't get DHCP response

**For Minikube:**
- Verify Kea pod is running: `kubectl get pods -n ochami`
- Check Kea logs: `kubectl logs -n ochami ochami-kea -c kea-dhcp4`

**For Quadlets:**
- Verify Kea container is running: `sudo podman ps | grep kea`
- Check Kea logs: `sudo podman logs ochami-kea-kea-dhcp4`

**Common checks:**
- Ensure the VM is on the `pxe-net` network: `virsh domiflist <vm-name>`
- **Important**: Kea must bind to the correct interface (`virbr-pxe`). Check logs for `listening on interface virbr-pxe`. If another DHCP server (like `dnsmasq` from `libvirt`'s default network) is running on the host, it may prevent Kea from binding. Use `--mode hardware` to handle this.

#### Node gets IP but fails TFTP

**For Minikube:**
- Check TFTP pod status: `kubectl get pods -n ochami -l app.kubernetes.io/component=tftp`

**For Quadlets:**
- Check TFTP container: `sudo podman ps | grep tftp`
- Check TFTP logs: `sudo podman logs ochami-tftp-tftp`

**Common checks:**
- Ensure port 69/UDP is not blocked or used by another process (e.g., `dnsmasq`)
- Test TFTP manually: `tftp 192.168.100.2 -c get undionly.kpxe`

#### iPXE loads but fails to download boot script

**For Minikube:**
- Verify HTTP server: `kubectl logs -n ochami ochami-http-server`
- Test HTTP: `curl http://192.168.100.2:30080/boot.ipxe`

**For Quadlets:**
- Verify HTTP server: `sudo podman logs ochami-http-server-http-server`
- Test HTTP: `curl http://192.168.100.2:80/boot.ipxe`

### Quadlets-Specific Issues

#### Services not starting

```bash
# Check systemd service status
sudo systemctl status ochami

# View service logs
sudo journalctl -u ochami -f

# Restart the service
sudo systemctl restart ochami
```

#### Container startup failures

```bash
# Check all containers (including failed)
sudo podman ps -a

# Check logs for failed container
sudo podman logs <container-name>

# Common issue: Port already in use
sudo ss -tlnp | grep -E "(67|69|80|27778|27779)"
```

#### BSS returns "Unknown node" (Quadlets only)

This is expected with Quadlets deployment. BSS requires ComponentEndpoints from SMD (populated via Redfish discovery), but the Redfish emulator doesn't work with Podman Quadlets due to StatefulSet limitations.

**Solution**: Quadlets deployment uses static `boot.ipxe` which bypasses BSS entirely. All VMs boot with the same kernel/initrd/parameters.

If you see this in BSS logs:
```
DEBUG: Unknown/disabled node, ID: 'x0c0s0b0n0'
```
This is normal for Quadlets - the static boot script will still work.

#### Quadlet YAML issues

```bash
# View the generated YAML
cat /etc/containers/systemd/ochami.yaml

# Check for sed replacement issues (should show localhost, not K8s DNS names)
grep -E "(ochami-postgres|ochami-smd|ochami-bss)" /etc/containers/systemd/ochami.yaml
```

### Checking the Full Boot Flow

**For Minikube:**
```bash
# Watch DHCP logs
kubectl logs -n ochami ochami-kea -c kea-dhcp4 -f &

# Watch HTTP logs
kubectl logs -n ochami ochami-http-server -f &

# Start the VM
sudo virsh start virtual-compute-node-0
```

**For Quadlets:**
```bash
# Watch DHCP logs
sudo podman logs -f ochami-kea-kea-dhcp4 &

# Watch HTTP logs
sudo podman logs -f ochami-http-server-http-server &

# Start the VM
sudo virsh start virtual-compute-node-0

# You should see:
# 1. DHCP DISCOVER/OFFER/REQUEST/ACK in Kea logs
# 2. GET /boot.ipxe in HTTP logs
# 3. GET /artifacts/vmlinuz-lts
# 4. GET /artifacts/initramfs-lts
# 5. GET /artifacts/rootfs.squashfs
```

### Quick Diagnostic Commands (Quadlets)

```bash
# Full system status
echo "=== Systemd Service ===" && sudo systemctl status ochami --no-pager
echo "=== Running Containers ===" && sudo podman ps
echo "=== SMD Health ===" && curl -s http://localhost:27779/hsm/v2/service/ready
echo "=== BSS Health ===" && curl -s http://localhost:27778/boot/v1/service/status
echo "=== HTTP Server ===" && curl -s -o /dev/null -w "%{http_code}" http://localhost:80/boot.ipxe
echo "=== VM Status ===" && sudo virsh list --all
```