# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM (or physical node) is network-booted using iPXE provided by a DHCP server. All services run within a Minikube cluster and are managed by a single Helm chart.

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
You should see pods for `ochami-kea`, `ochami-tftp`, `ochami-http-server`, `smd`, `bss`, and `postgres` running.

## Step 3: Create and Boot the VM (Local Mode)

1.  **Create the VM:**

    The `create_vm.sh` script uses `virt-install` to create a VM configured for PXE boot.

    ```bash
    sudo ./create_vm.sh
    ```
    This will print the MAC address of the new VM.

2.  **Start the VM:**

    Start the VM and attach to its console to watch the boot process.

    ```bash
    sudo virsh start --console virtual-compute-node
    ```

3.  **Watch it Boot!**

    If everything is configured correctly, you should see the following in the VM's console:
    *   The VM performs a PXE boot and gets an IP address from the `kea` DHCP server.
    *   The DHCP server points to `ipxe.efi` (served by `tftp`).
    *   The VM loads `ipxe.efi`, which then requests DHCP again.
    *   The DHCP server detects iPXE and provides the URL to the `boot.ipxe` script.
    *   iPXE downloads and executes `boot.ipxe`.
    *   The iPXE script downloads the **openSUSE** kernel and initramfs from the `http-server`.
    *   The Linux kernel starts booting into a live SLES/openSUSE environment.

## Cleanup

To remove the VM, Minikube cluster, network artifacts, and generated files, run:

```bash
./teardown.sh
```
*   Use `./teardown.sh --remove-images` to also delete the Docker images and CNI plugins.

This concludes the advanced tutorial. You have successfully booted a VM with a custom SLES image served entirely from within a Minikube cluster managed by a single Helm chart.

## Networking & Driver Challenges

This section explains the networking complexities involved when using different Minikube drivers or attempting to boot physical hardware.

### The Core Issue: Layer 2 Visibility

DHCP relies on broadcast packets (`DHCPDISCOVER`), which are not routed. The DHCP server (pod) and the client (VM or physical machine) must be on the same network segment (broadcast domain).

### Driver Compatibility Matrix

| Driver | Pod Location | Client Location | Status | Explanation |
| :--- | :--- | :--- | :--- | :--- |
| **`none`** | Host OS | Host Bridge | **Works** | The pod shares the Host OS network namespace, allowing it to bind directly to the Host Bridge (`virbr-pxe`) and receive broadcasts. |
| **`docker`** | Container | Host Bridge | **Fail** | The pod runs inside an isolated Docker container on a separate bridge. It cannot see broadcast traffic from the Host Bridge without complex, non-standard bridging. |
| **`kvm2` / `libvirt`** | Minikube VM | Host Bridge | **Conditional** | Fails by default because the Minikube VM is on a separate NAT network. **Works** only if you attach a secondary interface to the Minikube VM that is bridged to the Host Bridge (handled by `setup_minikube_net.sh`). |
| **Bare Metal** | (Any) | Physical Wire | **Fail** | Fails by default. The internal Host Bridge (`virbr-pxe`) is isolated from your physical Ethernet port. To work, you must bridge your physical NIC (e.g., `eth0`) to `virbr-pxe`, effectively turning your workstation into a switch. |

### Summary
*   **For Development/Testing:** The **`none`** driver is the most reliable method for this setup as it removes the network isolation layers between the pod and the host's virtual bridge.
*   **For Bare Metal:** Use the `--interface` flag in `deploy.sh` to target your physical network interface directly, ensuring the containerized DHCP server (running in host network mode) can see the physical network broadcasts.