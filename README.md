# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM (or physical node) is network-booted using iPXE provided by a DHCP server. All services run within a Minikube cluster and are managed by a single Helm chart.

## 1. Prerequisites

*   **Minikube** with the **`none` (bare-metal)** driver.
    *   *Note: The deployment script will automatically install necessary system dependencies (like `conntrack`, `cri-dockerd`, `cri-tools`, and CNI plugins) for Debian/Ubuntu systems.*
*   [Helm](https://helm.sh/docs/intro/install/)
*   [Docker](https://docs.docker.com/get-docker/) (Required for building images and running the `none` driver)
*   Libvirt & `virt-install` (For local VM testing)
*   `sudo` privileges (Required for `none` driver networking and artifact cleanup)

## Step 1: Deployment

Run the automated deployment script.

```bash
./deploy.sh
```

**What this script does:**
1.  **Checks & Installs Prerequisites**: Automatically installs `cri-dockerd`, CNI plugins, and other tools required for the Minikube `none` driver.
2.  **Builds SLES Image**: Builds a custom **openSUSE Leap 15.6 (SLES-based)** bootable image (kernel, initramfs, squashfs).
3.  **Starts Minikube**: Launches Minikube using the `none` driver directly on the host.
4.  **Configures Networking**:
    *   Detects your **Host IP** (e.g., your LAN IP) to ensure external physical nodes can reach the boot server.
    *   Sets up a local bridge (`virbr-pxe`) for local VM testing.
5.  **Deploys OpenCHAMI**: Installs the Helm chart with dynamic configuration to serve the boot artifacts via your Host IP.

**Rebuilding Images:**
If you want to force a rebuild of the SLES image (e.g., after modifying the build script), run:
```bash
./deploy.sh --rebuild
```

## Step 2: Verify the Deployment

Check that all the pods are running and the services are created.

```bash
minikube kubectl -- get pods -n ochami
minikube kubectl -- get services -n ochami
```
You should see pods for `coredhcp`, `ochami-http-server`, `smd`, `bss`, and `postgres` running.

## Step 3: Create and Boot the VM

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
    *   The VM performs a PXE boot and gets an IP address from the `coredhcp` server.
    *   The `coredhcp` server provides the URL to the `boot.ipxe` script (using your Host IP).
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