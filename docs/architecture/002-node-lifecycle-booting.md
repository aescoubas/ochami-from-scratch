# ADR 002: Node Lifecycle and Booting via iPXE

## Status
Accepted

## Context
A core function of OpenCHAMI is to discover, provision, and boot High Performance Computing (HPC) nodes. This requires a robust mechanism to boot bare-metal hardware and VMs over the network, transitioning them from an "unknown" discovery state to a "known" production state.

## Decision
We adopted an **iPXE-based** boot chain involving **Kea DHCP**, a **TFTP server**, and an **HTTP server**.

The boot process follows these stages:
1.  **DHCP Request:** Client broadcasts a request.
2.  **TFTP Boot:** Kea points the client to a TFTP server to download the initial iPXE binary (`undionly.kpxe` or `ipxe.efi`).
3.  **iPXE Boot:** The iPXE binary loads and makes a second DHCP request.
4.  **HTTP Boot:** Kea recognizes the iPXE client and points it to an HTTP URL (`boot.ipxe`) hosted by the `ochami-http-server`.
5.  **Artifact Fetch:** The client downloads the kernel, initramfs, and rootfs via HTTP and boots.

## Consequences
### Positive
- **Flexibility:** iPXE allows for powerful scripting and logic during the boot process (e.g., retries, conditional booting).
- **Performance:** Fetching large artifacts (kernel, rootfs) via HTTP is significantly faster and more reliable than TFTP.
- **Standardization:** Supports both Legacy BIOS and UEFI boot modes.

### Negative
- **Infrastructure Overhead:** Requires maintaining three separate services (DHCP, TFTP, HTTP) and ensuring they are correctly configured to talk to each other.
- **Network Complexity:** Relies on correct broadcasting and routing, which can be tricky in containerized environments (mitigated by `host` networking or specific bridge configurations).
