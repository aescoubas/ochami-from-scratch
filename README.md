# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM (or physical node) is network-booted using iPXE provided by a DHCP server. Services can be deployed using either **Minikube** (Kubernetes), **Quadlets** (systemd-managed Podman containers), or **Docker Compose**.

## Quick Start (Quadlets)

Deploy OpenCHAMI with Quadlets and create a test VM in one command:

```bash
./deploy.sh --method quadlets --vms 1
```

Verify the deployment:
```bash
# Check all services are running under openchami.target
systemctl list-dependencies openchami.target

# List running containers
sudo podman ps

# Check VM booted successfully (wait ~30 seconds after deploy)
ping -c 3 192.168.100.100
```

For detailed instructions, see the sections below.

## Quick Start (macOS with Docker Compose)

Deploy OpenCHAMI on macOS using Docker Compose:

```bash
./deploy.sh --method docker-compose
```

Verify the deployment:
```bash
# Check SMD is ready
curl -s http://localhost:27779/hsm/v2/service/ready

# Check BSS is ready
curl -s http://localhost:27778/boot/v1/service/status

# Check running services
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml -f ochami-docker-compose/docker-compose.macos.yml ps
```

To register a hardware node:
```bash
ORCHESTRATOR=docker-compose ./scripts/register_hardware_node.sh <MAC_ADDRESS> <IP_ADDRESS> [COMPONENT_ID] [NID]
```

To teardown:
```bash
./teardown.sh --method docker-compose -y
```

> **Note:** VM creation (`--vms N`) and PXE booting are not available on macOS. Use `--mode hardware` with physical nodes instead.

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

## Feature Matrix

The table below shows which combinations of **platform**, **deployment method**, and **mode** are supported.

| | Ubuntu — libvirt VMs | Ubuntu — hardware | macOS — libvirt VMs | macOS — hardware |
|---|:---:|:---:|:---:|:---:|
| **minikube** | Supported | Supported | — | Supported (services only) |
| **quadlets** | Supported | Supported | — | — |
| **docker-compose** | Supported | Supported | — | Supported (services only) |

**Legend:**
*   **Supported** — full functionality including VM creation, PXE boot, and all services.
*   **Supported (services only)** — OpenCHAMI services run and APIs are accessible; VM creation and host PXE boot are not available. Register physical nodes via `--nodes-file` or `./scripts/register_hardware_node.sh`.
*   **—** — not supported on this platform.

**Key notes:**
*   **libvirt VMs** mode (`--mode libvirt`, the default) creates virtual machines with KVM for testing. This requires Linux with libvirt/KVM — it is unavailable on macOS. The `--vms N` flag controls how many VMs to create.
*   **hardware** mode (`--mode hardware`) skips VM creation and targets physical nodes. Use `--nodes-file` to auto-register nodes during deployment, or register them individually afterward with `./scripts/register_hardware_node.sh`. On macOS, services are accessible via `localhost` but PXE booting from the macOS host is not supported (Docker Desktop cannot bridge DHCP to physical networks).
*   `--vms` and `--nodes-file` are independent — you can use either or both. Omitting both deploys services only.
*   **quadlets** requires systemd and is Linux-only.
*   On macOS, Docker Compose uses bridge networking (not `host` mode) with explicit port mappings. Minikube uses the `docker` driver instead of `none`.

## 1. Prerequisites

### For Minikube Deployment
*   **Minikube** with the **`none` (bare-metal)** driver (Linux) or **`docker`** driver (macOS).
    *   *Note (Linux): The deployment script will automatically install necessary system dependencies (like `conntrack`, `cri-dockerd`, `cri-tools`, and CNI plugins) for Debian/Ubuntu systems.*
*   [Helm](https://helm.sh/docs/intro/install/)
*   [Docker](https://docs.docker.com/get-docker/) (Required for building images and running the `none` driver)

### For Quadlets Deployment (Linux only)
*   **Podman** (version 4.0+, with quadlet support)
*   `envsubst` (from the `gettext` package — used to process config templates)
*   *Note: Quadlets deployment uses native podman `.container` files managed by systemd, with each service running as an independent unit under `openchami.target`*

### For Docker Compose Deployment
*   [Docker](https://docs.docker.com/get-docker/) with the **Compose plugin** (or standalone `docker-compose`)
*   *Note: Docker Compose deployment uses standard Docker networking with port mappings*

### macOS Prerequisites
*   [Docker Desktop](https://www.docker.com/products/docker-desktop/) (must be running)
*   [Homebrew](https://brew.sh/) (for installing dependencies)
*   The deploy script will automatically install: `gettext` (envsubst), `python3`/PyYAML, GNU `grep`, `minikube`, and `helm` via Homebrew

### Common Requirements (Linux)
*   Libvirt & `virt-install` (For local VM testing)
*   `sudo` privileges (Required for networking and container management)

## Step 1: Deployment

### Option A: Minikube Deployment

Run the automated deployment script with Minikube (Kubernetes):

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

### Option C: Docker Compose Deployment

Deploy using Docker Compose, which runs containers with standard Docker networking:

```bash
./deploy.sh --method docker-compose
```

To deploy with test VMs:
```bash
./deploy.sh --method docker-compose --vms 1
```

**Common Options:**
*   `--method [minikube|quadlets|docker-compose]`: Choose the deployment method (required)
*   `--vms N`: Automatically create N test VMs (named `virtual-compute-node-0`, `virtual-compute-node-1`, etc.)
*   `--rebuild`: Force a rebuild of container images
*   `--phy-iface IFACE`: Bridge a physical interface for bare-metal testing
*   `--ip ADDRESS`: Set the PXE server IP (default: 192.168.100.2)
*   `--cidr CIDR`: Set the network CIDR (default: 24)
*   `--nodes-file FILE`: CSV file with hardware nodes to auto-register (see [Automated Hardware Node Registration](#4b-automated-hardware-node-registration))

### What the deployment script does:

| Step | Minikube | Quadlets | Docker Compose |
|------|----------|----------|----------------|
| 1. Prerequisites | Installs cri-dockerd, CNI plugins | Checks for podman, envsubst | Checks for docker compose |
| 2. Build Images | Builds with Docker, loads into Minikube | Builds with Podman | Builds with Docker |
| 3. Start Orchestrator | Starts Minikube with `none` driver | N/A (uses systemd) | N/A (uses Docker daemon) |
| 4. Configure Network | Creates `virbr-pxe` bridge, assigns 192.168.100.2 | Same | Same |
| 5. Deploy Services | Helm install to Kubernetes | Installs `.container` quadlet files + `openchami.target` | Docker Compose up |
| 6. Register Hardware Nodes | Registers nodes from CSV if `--nodes-file` specified | Same | Same |
| 7. Create VMs | Creates Libvirt VMs if `--vms` specified | Same | Same |

### Key Differences Between Methods

| Feature | Minikube | Quadlets | Docker Compose |
|---------|----------|----------|----------------|
| Boot Script | BSS dynamic (per-node) | Static boot.ipxe (all nodes same) | Static boot.ipxe (all nodes same) |
| Service Discovery | Kubernetes DNS | Host networking (localhost) | Docker networking (localhost) |
| Service Lifecycle | Kubernetes pods | Individual systemd services | Docker Compose services |
| Redfish Emulator | Works | Works (individual containers per VM) | Works (via `--profile emulator`) |
| Management | `kubectl` commands | `systemctl` + `podman` commands | `docker compose` commands |

**Rebuilding Images:**
```bash
./deploy.sh --method quadlets --rebuild
./deploy.sh --method docker-compose --rebuild
```

## Step 1b: Deployment (Bare Metal Mode)

To boot physical machines, you can bridge a physical interface to the PXE network. This allows external devices to reach the DHCP and TFTP services.

```bash
./deploy.sh --method minikube --phy-iface eth1
```

*   `--phy-iface`: The physical interface on your host (e.g., `eth1`, `eno1`) to bridge to the PXE network.
    *   **Note:** The interface will be brought UP and attached to the `virbr-pxe` bridge. Any existing IP configuration on this interface effectively becomes secondary to the bridge configuration.
    *   **Warning:** Ensure this interface is connected to an isolated network switch. Do not connect it to a corporate LAN as it will serve DHCP.

If your host has `libvirt` installed, its `dnsmasq` service may conflict with Kea DHCP. Use the `--mode hardware` option to automatically stop and disable libvirt's default network and skip creating the `pxe-net` virtual network (since you are using a physical interface).
```bash
./deploy.sh --method minikube --mode hardware --phy-iface eth1
```

You can also combine this with custom IP ranges if your physical network requires it:

```bash
./deploy.sh --method minikube --phy-iface eth1 --ip 192.168.50.1 --cidr 24 \
            --dhcp-start 192.168.50.100 --dhcp-end 192.168.50.200
```

To fully automate hardware deployment (services + node registration in one command), add `--nodes-file`:

```bash
./deploy.sh --method minikube --mode hardware --interface ens160 \
            --ip 148.187.1.68 --cidr 28 \
            --dhcp-start 148.187.1.69 --dhcp-end 148.187.1.78 \
            --nodes-file nodes.csv
```

See [Automated Hardware Node Registration](#4b-automated-hardware-node-registration) for the CSV format.

## Step 2: Verify the Deployment

### For Minikube

Check that all the pods are running and the services are created.

```bash
minikube kubectl -- get pods -n ochami
minikube kubectl -- get services -n ochami
```

You should see pods for `ochami-kea`, `ochami-tftp`, `ochami-http-server`, `smd`, `bss`, and `postgres` running.

### For Quadlets

Check the systemd services and running containers:

```bash
# Check all services under openchami.target
systemctl list-dependencies openchami.target

# Check individual service status
sudo systemctl status smd
sudo systemctl status bss
sudo systemctl status kea

# List running containers
sudo podman ps

# Expected services (each runs as an independent systemd unit):
# - postgres, smd-init, smd, bss-init, bss
# - cloud-init-server, pcs-init, pcs
# - kea-init, kea, kea-ctrl-agent, kea-sidecar
# - stork-server, stork-agent
# - http-server, tftp
```

### For Docker Compose

Check the running services:

```bash
# List running containers
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml ps

# View logs
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs
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
# For Quadlets / Docker Compose (static boot script):
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
sudo journalctl -u http-server --no-pager -n 20

# You should see requests for:
# - /boot.ipxe (or /boot/v1/bootscript for Minikube)
# - /artifacts/vmlinuz-lts
# - /artifacts/initramfs-lts
# - /artifacts/rootfs.squashfs
```

**For Docker Compose:**
```bash
# Check HTTP server logs
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs http-server | tail -10
```

### 3e. Full Boot Verification Checklist

Run these commands to verify a successful boot:

```bash
# 1. Check VM is running
sudo virsh domstate virtual-compute-node-0

# 2. Check DHCP lease was issued
# Quadlets:
sudo journalctl -u kea --no-pager | grep -i "lease"
# Docker Compose:
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs kea 2>&1 | grep -i "lease"

# 3. Check boot artifacts were downloaded
# Quadlets:
sudo journalctl -u http-server --no-pager | grep -E "(vmlinuz|initramfs|rootfs)"
# Docker Compose:
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs http-server 2>&1 | grep -E "(vmlinuz|initramfs|rootfs)"

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

### 4b. Automated Hardware Node Registration

You can register multiple hardware nodes automatically during deployment using a CSV inventory file with `--nodes-file`:

1.  **Create the inventory file:**

    ```bash
    cp nodes.csv.example nodes.csv
    ```

    Edit `nodes.csv` with your hardware inventory:
    ```csv
    # mac,ip,component_id,nid
    50:6b:4b:d5:1d:5d,148.187.1.69,x1000c0s0b0n0,1000
    AA:BB:CC:DD:EE:01,148.187.1.70,x1000c0s1b0n0,1001
    ```

2.  **Deploy with automatic registration:**

    ```bash
    ./deploy.sh --method minikube --mode hardware --interface ens160 \
      --ip 148.187.1.68 --cidr 28 \
      --dhcp-start 148.187.1.69 --dhcp-end 148.187.1.78 \
      --nodes-file nodes.csv
    ```

    The deploy script will:
    - Start all OpenCHAMI services
    - Register BSS default boot parameters
    - Read the CSV and register each node in SMD + BSS
    - Apply the `boot_mac` database workaround for each node

    After deployment, the hardware nodes will PXE boot without any manual registration steps.

### 4c. Manual Hardware Node Registration

To register a single hardware node after deployment, use the standalone script:

```bash
# Usage: ./scripts/register_hardware_node.sh <MAC_ADDRESS> <IP_ADDRESS> [COMPONENT_ID] [NID]
./scripts/register_hardware_node.sh 00:11:22:33:44:55 192.168.50.50 x1000c0s0b0n0 1000

# For quadlets or docker-compose deployments, set the ORCHESTRATOR env var:
ORCHESTRATOR=quadlets ./scripts/register_hardware_node.sh 00:11:22:33:44:55 192.168.50.50
```

### 4d. Boot the Hardware
Power on the node. Once registered and synced, Kea will assign the static production IP and serve the boot image.

## Cleanup

### Using the Teardown Script

To remove the VM, cluster/services, network artifacts, and generated files:

```bash
./teardown.sh --method quadlets
./teardown.sh --method docker-compose
./teardown.sh --method minikube
```

**Available options:**
| Option | Description |
| :--- | :--- |
| `--method METHOD` | Deployment method to tear down: `minikube`, `quadlets`, or `docker-compose` (required) |
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

# Stop all OpenCHAMI services
sudo systemctl stop openchami.target

# Remove quadlet container files and target
sudo rm -f /etc/containers/systemd/*.container
sudo rm -f /etc/systemd/system/openchami.target
sudo systemctl daemon-reload

# Remove config directory
sudo rm -rf /etc/openchami

# Remove podman volumes
sudo podman volume rm systemd-postgres-data systemd-kea-sockets 2>/dev/null || true

# Remove all containers
sudo podman rm -f -a

# Clean up libvirt network
virsh net-destroy pxe-net
virsh net-undefine pxe-net

# Remove network interface
sudo ip link delete ochami-dummy 2>/dev/null || true
```

### Manual Cleanup (Docker Compose)

If you need to manually clean up a Docker Compose deployment:

```bash
# Stop and remove VMs
sudo virsh destroy virtual-compute-node-0
sudo virsh undefine virtual-compute-node-0

# Stop Docker Compose services and remove volumes
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml down -v --remove-orphans

# Clean up libvirt network
virsh net-destroy pxe-net
virsh net-undefine pxe-net

# Remove network interface
sudo ip link delete ochami-dummy 2>/dev/null || true

# Remove generated config files
rm -f ochami-docker-compose/.env
rm -f ochami-docker-compose/configs/kea-dhcp4.conf
rm -f ochami-docker-compose/configs/nginx-default.conf
rm -f ochami-docker-compose/configs/boot.ipxe
rm -f ochami-docker-compose/configs/stork-server.env
```

## Components Overview

| Component | Purpose |
| :--- | :--- |
| **Kea DHCP** | Main DHCP server. Assigns IPs and boot options (Next-Server, Boot-File). |
| **SMD Sync Sidecar** | Python script syncing SMD inventory to Kea's database for static reservations. |
| **TFTP Server** | Serves iPXE binaries (`undionly.kpxe`, `ipxe.efi`). |
| **HTTP Server** | Nginx proxy serving `boot.ipxe` script, kernel, initramfs, rootfs, and routing to backend services. |
| **SMD** | State Management Daemon - hardware inventory database. |
| **BSS** | Boot Script Service - provides dynamic boot scripts for known nodes. |
| **PCS** | Power Control Service - manages node power states via Redfish. |
| **Cloud-Init** | Cloud-init server providing instance metadata and user-data to booted nodes. |
| **PostgreSQL** | Persistent storage for SMD, BSS, Kea, PCS, and Stork. |
| **Stork** | Kea DHCP monitoring dashboard (server + agent). |
| **Redfish Emulator** | Lightweight emulator that controls VM power (On/Off/Reboot) via Libvirt, exposing a Redfish API. |

## 5. Using the Redfish Emulator

The deployment includes an optional **Redfish Emulator** that mimics a Baseboard Management Controller (BMC) for each VM. This allows you to control the VM's power state (On, Off, Reboot) via standard Redfish API calls.

### 5a. Enable the Emulator
The emulator is automatically enabled when you deploy with VMs using the `--vms` flag. It works with all deployment methods:

```bash
./deploy.sh --method minikube --vms 1
./deploy.sh --method quadlets --vms 1
./deploy.sh --method docker-compose --vms 1
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
- Verify Kea service is running: `sudo systemctl status kea`
- Check Kea logs: `sudo journalctl -u kea --no-pager -n 50`

**For Docker Compose:**
- Verify Kea container is running: `docker compose -p ochami -f ochami-docker-compose/docker-compose.yml ps | grep kea`
- Check Kea logs: `docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs kea`

**Common checks:**
- Ensure the VM is on the `pxe-net` network: `virsh domiflist <vm-name>`
- **Important**: Kea must bind to the correct interface (`virbr-pxe`). Check logs for `listening on interface virbr-pxe`. If another DHCP server (like `dnsmasq` from `libvirt`'s default network) is running on the host, it may prevent Kea from binding. Use `--mode hardware` to handle this.

#### Node gets IP but fails TFTP

**For Minikube:**
- Check TFTP pod status: `kubectl get pods -n ochami -l app.kubernetes.io/component=tftp`

**For Quadlets:**
- Check TFTP service: `sudo systemctl status tftp`
- Check TFTP logs: `sudo journalctl -u tftp --no-pager -n 50`

**For Docker Compose:**
- Check TFTP container: `docker compose -p ochami -f ochami-docker-compose/docker-compose.yml ps | grep tftp`
- Check TFTP logs: `docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs tftp`

**Common checks:**
- Ensure port 69/UDP is not blocked or used by another process (e.g., `dnsmasq`)
- Test TFTP manually: `tftp 192.168.100.2 -c get undionly.kpxe`

#### BSS returns 5xx / node shows "Unknown/disabled" in BSS logs

If BSS logs show `Unknown/disabled node` and the iPXE client gets an HTTP 5xx error, the node is registered in SMD but BSS doesn't recognize it as a known node. This is caused by the BSS `boot_mac` + `nid` workaround (see [Known Issues & Workarounds](#known-issues--workarounds)).

**Diagnosis:**
```bash
# Check the BSS nodes table
# For Minikube:
minikube kubectl -- exec -n ochami ochami-postgres -- \
  psql -U bss-user -d bssdb -c "SELECT xname, boot_mac, nid FROM nodes;"

# For Quadlets:
sudo podman exec $(sudo podman ps --format "{{.Names}}" | grep postgres | head -n 1) \
  psql -U bss-user -d bssdb -c "SELECT xname, boot_mac, nid FROM nodes;"

# For Docker Compose:
docker exec $(docker ps --format "{{.Names}}" | grep postgres | head -n 1) \
  psql -U bss-user -d bssdb -c "SELECT xname, boot_mac, nid FROM nodes;"
```

If `boot_mac` is NULL or `nid` is 0, apply the fix manually:
```bash
# Replace values with your node's MAC, NID, and xname
minikube kubectl -- exec -n ochami ochami-postgres -- \
  psql -U bss-user -d bssdb -c "UPDATE nodes SET boot_mac = '50:6b:4b:d5:1d:5d', nid = 1000 WHERE xname = 'x1000c0s0b0n0';"
```

Then restart BSS to reload its cached state:
```bash
# Minikube:
minikube kubectl -- delete pod -n ochami -l app.kubernetes.io/component=bss
# Quadlets:
sudo systemctl restart bss
# Docker Compose:
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml restart bss
```

> **Note:** The deploy scripts (`--nodes-file`) and registration scripts apply this workaround automatically. This manual fix is only needed if the workaround failed silently or if you registered nodes through the API directly.

#### iPXE loads but fails to download boot script

**For Minikube:**
- Verify HTTP server: `kubectl logs -n ochami ochami-http-server`
- Test HTTP: `curl http://192.168.100.2:30080/boot.ipxe`

**For Quadlets:**
- Verify HTTP server: `sudo systemctl status http-server` / `sudo journalctl -u http-server --no-pager -n 50`
- Test HTTP: `curl http://192.168.100.2:80/boot.ipxe`

**For Docker Compose:**
- Verify HTTP server: `docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs http-server`
- Test HTTP: `curl http://192.168.100.2:80/boot.ipxe`

### Quadlets-Specific Issues

#### Services not starting

```bash
# Check the full service dependency tree
systemctl list-dependencies openchami.target

# Check status of a specific service (look for × = failed, ○ = not started)
sudo systemctl status smd
sudo systemctl status kea-init

# View logs for a specific service
sudo journalctl -u smd --no-pager -n 50
sudo journalctl -u kea-init --no-pager -n 50

# Restart a single service
sudo systemctl restart smd

# Restart all services
sudo systemctl restart openchami.target
```

#### Container startup failures

```bash
# Check all containers (including failed)
sudo podman ps -a

# Check logs for failed container
sudo podman logs systemd-smd
sudo podman logs systemd-kea

# Common issue: Port already in use
sudo ss -tlnp | grep -E "(67|69|80|27778|27779)"
```

#### Init services failed (×)

If init services like `kea-init` or `pcs-init` show as failed, their dependent services won't start:

```bash
# Check what failed
sudo journalctl -u kea-init --no-pager
sudo journalctl -u pcs-init --no-pager

# Re-run a failed init (reset + restart)
sudo systemctl reset-failed kea-init
sudo systemctl start kea-init
```

#### Checking installed quadlet files

```bash
# List installed container files
ls -la /etc/containers/systemd/*.container

# Check the target file
cat /etc/systemd/system/openchami.target

# View generated config files
ls -la /etc/openchami/configs/

# View environment file
cat /etc/openchami/openchami.env
```

### Docker Compose-Specific Issues

#### Container startup failures

```bash
# Check all containers (including stopped)
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml ps -a

# Check logs for a specific service
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs <service-name>

# Common issue: Port already in use
sudo ss -tlnp | grep -E "(67|69|80|27778|27779)"
```

#### Config file issues

```bash
# Check generated config files exist
ls -la ochami-docker-compose/configs/kea-dhcp4.conf
ls -la ochami-docker-compose/configs/nginx-default.conf

# Re-generate by re-running deploy
./deploy.sh --method docker-compose
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
sudo journalctl -u kea -f &

# Watch HTTP logs
sudo journalctl -u http-server -f &

# Start the VM
sudo virsh start virtual-compute-node-0

# You should see:
# 1. DHCP DISCOVER/OFFER/REQUEST/ACK in Kea logs
# 2. GET /boot.ipxe in HTTP logs
# 3. GET /artifacts/vmlinuz-lts
# 4. GET /artifacts/initramfs-lts
# 5. GET /artifacts/rootfs.squashfs
```

**For Docker Compose:**
```bash
# Watch DHCP logs
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs -f kea &

# Watch HTTP logs
docker compose -p ochami -f ochami-docker-compose/docker-compose.yml logs -f http-server &

# Start the VM
sudo virsh start virtual-compute-node-0
```

### Quick Diagnostic Commands (Quadlets)

```bash
# Service dependency tree
echo "=== Service Tree ===" && systemctl list-dependencies openchami.target
echo "=== Running Containers ===" && sudo podman ps
echo "=== SMD Health ===" && curl -s http://localhost:27779/hsm/v2/service/ready
echo "=== BSS Health ===" && curl -s http://localhost:27778/boot/v1/service/status
echo "=== HTTP Server ===" && curl -s -o /dev/null -w "%{http_code}" http://localhost:80/boot.ipxe
echo "=== VM Status ===" && sudo virsh list --all

# Individual service management
sudo systemctl status smd        # Check a specific service
sudo systemctl restart bss       # Restart a single service
sudo journalctl -u kea -f        # Follow logs for a service
```

### Quick Diagnostic Commands (Docker Compose)

```bash
# Full system status
echo "=== Running Services ===" && docker compose -p ochami -f ochami-docker-compose/docker-compose.yml ps
echo "=== SMD Health ===" && curl -s http://localhost:27779/hsm/v2/service/ready
echo "=== BSS Health ===" && curl -s http://localhost:27778/boot/v1/service/status
echo "=== HTTP Server ===" && curl -s -o /dev/null -w "%{http_code}" http://localhost:80/boot.ipxe
echo "=== VM Status ===" && sudo virsh list --all
```

## Known Issues & Workarounds

### BSS `boot_mac` and `nid` not saved by API

**Affected component:** BSS (Boot Script Service)

**Problem:** When boot parameters are registered via the BSS API (`PUT /boot/v1/bootparameters`), BSS creates a row in its internal `nodes` table but fails to populate the `boot_mac` and `nid` columns (they default to NULL and 0 respectively). Without `boot_mac`, BSS cannot look up boot parameters when a node requests a boot script by MAC address. Without `nid`, BSS treats the node as "Unknown/disabled" even though it can see the node in SMD.

**Symptom:** BSS logs show `Unknown/disabled node, ID: 'x1000c0s0b0n0'` and the iPXE client receives an HTTP 5xx error. In severe cases, BSS panics with `slice bounds out of range [-1:]` in `checkState`.

**Workaround:** The deploy scripts and registration scripts automatically apply a direct database update after registering boot parameters:

```sql
UPDATE nodes SET boot_mac = '<MAC>', nid = <NID> WHERE xname = '<COMPONENT_ID>';
```

This workaround is applied in:
- `register_hardware_nodes_from_file()` in `scripts/common.sh` (batch registration via `--nodes-file`)
- `scripts/register_hardware_node.sh` (standalone hardware node registration)
- `scripts/register_local_vm.sh` (VM registration)

After the database update, BSS must be restarted (or must poll SMD again) to pick up the change in its cached state.

### Kea DHCP `${net0/mac}` resolves wrong NIC on multi-NIC hardware

**Affected component:** Kea DHCP configuration

**Problem:** The iPXE variable `${net0/mac}` always refers to the first network interface (net0), which may not be the NIC that actually PXE booted. On multi-NIC hardware (e.g., ConnectX-5 dual-port), the boot NIC might be `net3` while `${net0/mac}` returns a completely different MAC address.

**Fix:** The Kea config templates use `${mac}` instead of `${net0/mac}`. The `${mac}` variable in Kea's DHCP context resolves to the MAC address from the DHCP request itself, which is always the correct boot NIC.

### `configure_hardware_network()` stdout pollution

**Affected component:** `scripts/common.sh`

**Problem:** `configure_hardware_network()` is called via command substitution (`PXE_INTERFACE=$(configure_hardware_network ...)`), so its stdout is captured as the return value. Status messages printed to stdout were concatenated with the interface name, producing values like `"Checking for conflicting...ens160"` instead of `"ens160"`.

**Fix:** All informational messages in `configure_hardware_network()` are now redirected to stderr (`>&2`). Only the final interface name is printed to stdout.