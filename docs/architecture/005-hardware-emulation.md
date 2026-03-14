# ADR 005: Hardware Emulation with Redfish

## Status
Accepted

## Context
Developing and testing the control plane requires interacting with hardware management interfaces (BMCs) to perform power operations (on, off, reboot). Developers often do not have access to physical hardware labs, or need to spin up transient environments quickly.

## Decision
We integrated a **Redfish Emulator** into the deployment stack.

- **Function:** It exposes a REST API compliant with the DMTF Redfish standard.
- **Backend:** It translates Redfish commands into `libvirt` calls to control local KVM/QEMU virtual machines.
- **Deployment:** Deployed as a StatefulSet to maintain a stable identity corresponding to the virtual compute nodes.

## Consequences
### Positive
- **Accessibility:** Enables full "hardware" lifecycle testing on a standard laptop.
- **Speed:** Virtual machines boot and reboot much faster than physical servers.
- **API Compliance:** Allows validting client code against a standard Redfish API structure.

### Negative
- **Fidelity:** The emulator may not perfectly replicate all the quirks and specific behaviors of real hardware vendors' BMCs.
- **Maintenance:** Requires maintaining the mapping logic between Redfish and Libvirt.
