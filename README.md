# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM is network-booted using iPXE provided by a DHCP server. All services run within a Minikube cluster and are managed by a single Helm chart.

## 1. Prerequisites

*   [Minikube](https://minikube.sigs.k8s.io/docs/start/) with the docker driver.
*   [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
*   [Helm](https://helm.sh/docs/intro/install/)
*   [Docker](https://docs.docker.com/get-docker/)
*   Libvirt & `virt-install`

## Step 1: Deployment

Run the automated deployment script. This will:
1.  Build all necessary container images (Fedora-based by default).
2.  Start Minikube (if not running).
3.  Configure the `pxe-net` network and attach it to Minikube.
4.  Deploy the OpenCHAMI services using Helm with the correct PXE configuration.

```bash
./deploy.sh
```

## Step 2: Verify the Deployment

    Check that all the pods are running and the services are created.

    ```bash
    kubectl get pods
    kubectl get services
    ```
    You should see pods for `coredhcp`, `ochami-http-server`, `smd`, `bss`, and `postgres`, and their corresponding services.

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
    *   The `coredhcp` server provides the URL to the `boot.ipxe` script.
    *   iPXE downloads and executes `boot.ipxe`.
    *   The iPXE script downloads the kernel and initramfs from the `http-server`.
    *   The Linux kernel starts booting.

This concludes the advanced tutorial. You have successfully booted a VM with a custom image served entirely from within a Minikube cluster managed by a single Helm chart.
