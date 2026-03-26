# OpenCHAMI Demo — Sysadmin RPM Deployment

Step-by-step scenario: spin up a VM with OpenCHAMI installed, then interact
with the services using the `ochami` CLI.

## Prerequisites (build machine)

These steps run on the build host **before** the demo.

### 1. Build the CSCS RPM

```bash
cd operations/ochami-from-scratch

# Generate quadlets with JFrog image refs, then build the RPM
make rpm PROFILE=cscs
```

This produces `ochami-from-scratch-<version>.noarch.rpm` with quadlet files
that reference `jfrog.svc.cscs.ch/docker/openchami/cscs-*`.

### 2. Build the ochami CLI

```bash
cd shared/ochami-cli
make
# Binary is at ./ochami
```

### 3. Create the demo VM

A single script handles everything: downloads the AlmaLinux 9 cloud image,
creates a libvirt VM, copies in the RPM and CLI, installs them, and starts
the OpenCHAMI services.

```bash
cd operations/ochami-from-scratch
./scripts/ops/create-demo-vm.sh
```

The script auto-detects the RPM and CLI binary. To override:

```bash
./scripts/ops/create-demo-vm.sh \
  --rpm path/to/ochami-from-scratch.rpm \
  --cli path/to/ochami
```

On first run it downloads the AlmaLinux cloud image (~600 MB, cached for
subsequent runs). The VM pulls container images from JFrog on first start,
so allow a couple of minutes for all services to come up.

When the script finishes it prints the VM IP and connection details:

```
============================================================
  OpenCHAMI Demo VM Ready
============================================================

  VM name:    openchami-demo
  IP:         192.168.122.x
  User:       almalinux
  Password:   ochami

  SSH:        ssh -i ~/.local/state/openchami/demo/ssh/id_ed25519 almalinux@192.168.122.x
  Console:    virsh console openchami-demo
  ...
```

---

## Demo Script (run inside the VM)

SSH into the VM (use the SSH command from the script output above) or connect
via the console:

```bash
virsh console openchami-demo
# login: almalinux / ochami
```

Everything below runs on the VM. The CLI config is already set up by the
provisioning script.

> **Note:** SMD uses HTTPS with a self-signed certificate. Add `-k` to all
> `ochami smd` commands to skip TLS verification.

### Step 1 — Check service health

```bash
# Check that all containers are running
sudo systemctl list-units 'openchami-*' --no-pager

# Check SMD status via the CLI
ochami smd service status --no-token -k

# Check BSS status
ochami bss service status --no-token
```

Expected output:
```
{"Code":0,"Message":"HSM is healthy"}
{"bss-status":"running"}
```

### Step 2 — View the empty inventory

```bash
# List all components — should be empty
ochami smd component get --no-token -k

# List all groups — should be empty
ochami smd group get --no-token -k
```

### Step 3 — Register compute nodes

```bash
# Add two compute nodes to SMD
ochami smd component add --no-token -k -d '{
  "Components": [
    {
      "ID": "x1000c0s0b0n0",
      "Type": "Node",
      "State": "Ready",
      "Role": "Compute",
      "NID": 1
    },
    {
      "ID": "x1000c0s1b0n0",
      "Type": "Node",
      "State": "Ready",
      "Role": "Compute",
      "NID": 2
    }
  ]
}'
```

### Step 4 — Register network interfaces (MAC + IP)

```bash
# Register ethernet interfaces for the nodes
ochami smd iface add --no-token -k -d '{
  "EthernetInterfaces": [
    {
      "ComponentID": "x1000c0s0b0n0",
      "MACAddress": "02:00:00:00:00:01",
      "IPAddresses": [{"IPAddress": "192.168.100.101"}],
      "Description": "eth0"
    },
    {
      "ComponentID": "x1000c0s1b0n0",
      "MACAddress": "02:00:00:00:00:02",
      "IPAddresses": [{"IPAddress": "192.168.100.102"}],
      "Description": "eth0"
    }
  ]
}'
```

### Step 5 — Verify the inventory

```bash
# List all components — now shows 2 nodes
ochami smd component get --no-token -k

# Query a specific node
ochami smd component get --no-token -k x1000c0s0b0n0

# List all ethernet interfaces
ochami smd iface get --no-token -k
```

### Step 6 — Create a group

```bash
# Create a "compute" group
ochami smd group add --no-token -k -d '{
  "label": "compute",
  "description": "Compute nodes",
  "members": {
    "ids": ["x1000c0s0b0n0", "x1000c0s1b0n0"]
  }
}'

# Verify the group
ochami smd group get --no-token -k
```

### Step 7 — Set boot parameters

```bash
# Set default boot parameters for all nodes
ochami bss boot params add --no-token -d '{
  "kernel": "http://192.168.100.1/boot/kernel",
  "initrd": "http://192.168.100.1/boot/initrd",
  "params": "console=ttyS0,115200 root=live:http://192.168.100.1/boot/rootfs.squashfs ip=dhcp rd.neednet=1"
}'

# Retrieve boot parameters
ochami bss boot params get --no-token
```

### Step 8 — Query boot script for a specific node

```bash
# Get the iPXE boot script that BSS would serve to this node
ochami bss boot script get --no-token --mac 02:00:00:00:00:01
```

### Step 9 — Check power control service

```bash
# Check PCS dependencies and readiness
ochami pcs service status --no-token
```

### Step 10 — Clean up (optional)

```bash
# Delete a node
ochami smd component delete --no-token -k x1000c0s1b0n0

# Verify deletion
ochami smd component get --no-token -k
```

---

## Quick Reference

| Service | Port | CLI prefix |
|---------|------|------------|
| SMD     | 27779 | `ochami smd` |
| BSS     | 27778 | `ochami bss` |
| Cloud-init | 27777 | `ochami cloud-init` |
| PCS     | 28007 | `ochami pcs` |
| Kea DHCP | 67 | (no CLI) |
| HTTP/boot | 80 | (curl) |

| VM credential | Value |
|---------------|-------|
| User | `almalinux` |
| Password | `ochami` |
| sudo | passwordless |

## Teardown

```bash
./scripts/ops/create-demo-vm.sh --destroy
```
