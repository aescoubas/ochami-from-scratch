# Advanced Tutorial: Booting a Custom Image with OpenCHAMI

This tutorial demonstrates a more advanced scenario where a custom-built Linux image is served via a web server and a VM is network-booted using iPXE provided by a DHCP server. All services run within a Minikube cluster and are managed by a single Helm chart.

## 1. Prerequisites

*   [Minikube](https://minikube.sigs.k8s.io/docs/start/) with the docker driver.
*   [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
*   [Helm](https://helm.sh/docs/intro/install/)
*   [Docker](https://docs.docker.com/get-docker/)
*   Libvirt & `virt-install`

## Step 1: Build and Load Custom Image and Server

This step builds the custom image artifacts, and then builds the `http-server` docker image and loads it into Minikube.

```bash
./build_and_load_http_server.sh
```

This script will:
1.  Create `vmlinuz-lts`, `initramfs-lts`, and `rootfs.squashfs`.
2.  Place these artifacts in `ochami-helm/http-server/artifacts/`.
3.  Build the `localhost/http-server:latest` docker image.
4.  Load the `localhost/http-server:latest` image into your Minikube cluster.

## Step 2: Configure and Deploy to Minikube

Now we'll deploy the DHCP and HTTP servers to Minikube using the `ochami-helm` chart.

1.  **Get Minikube IP:**

    We need the IP address of the Minikube cluster to configure the services.

    ```bash
    export MINIKUBE_IP=$(minikube ip)
    echo "Minikube IP: $MINIKUBE_IP"
    ```

2.  **Prepare Helm Values:**

    Replace the placeholder in the iPXE script with the actual Minikube IP.

    ```bash
    sed -i "s/{{MINIKUBE_IP}}/$MINIKUBE_IP/g" ochami-helm/files/boot.ipxe
    ```

    Create a `coredhcp-values.yaml` file to override the default `coredhcp` configuration in the Helm chart.

    ```bash
    cat <<EOF > coredhcp-values.yaml
    coredhcp:
      customConfig: |
        server4:
          listen: "0.0.0.0:67"
          plugins:
            - server_id: ${MINIKUBE_IP}
            - router: ${MINIKUBE_IP}
            - dns: 8.8.8.8
            - netmask: 255.255.255.0
            - range: /tmp/coredhcp.leases 192.168.39.100 192.168.39.200 1h # Adjust if your minikube network is different
            - nbp: "http://${MINIKUBE_IP}:30080/boot.ipxe"
    EOF
    ```

3.  **Deploy the Helm Chart:**

    Install the `ochami-helm` chart with the custom values. This will deploy all the necessary services, including our `http-server` and the reconfigured `coredhcp`.

    ```bash
    helm install ochami ./ochami-helm -f coredhcp-values.yaml
    # alternatively:
    helm upgrade ochami ./ochami-helm -f coredhcp-values.yaml
    ```

4.  **Verify the Deployment:**

    Check that all the pods are running and the services are created.

    ```bash
    kubectl get pods
    kubectl get services
    ```
    You should see pods for `coredhcp`, `ochami-http-server`, `smd`, `bss`, and `postgres`, and their corresponding services.

## Step 4: Create and Boot the VM

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
