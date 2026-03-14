# ADR 006: Dynamic Boot Configuration via BSS

## Status
Accepted

## Context
While the HTTP server handles the delivery of static, large artifacts (kernels, initrd images), the boot process often requires dynamic, node-specific configuration. Different nodes may need:
- Different kernel parameters (e.g., `console=` settings).
- Different boot images based on their role (compute vs. storage).
- Specific cloud-init data sources.
- Reporting of boot status.

Using a single static `boot.ipxe` script for the entire cluster is insufficient for these requirements.

## Decision
We utilize the **Boot Script Service (BSS)** as the dynamic component of the boot control plane.

- **Role:** BSS generates iPXE scripts on-the-fly when requested by a booting node.
- **Data Source:** It queries the State Management Database (SMD) to determine the node's identity and assigned boot parameters.
- **Integration:** The initial static boot script (served by the HTTP server) chains into BSS (e.g., `chain http://bss:27778/boot/v1/bootscript`).

## Consequences
### Positive
- **Granularity:** Allows per-node or per-group boot customization without modifying static files.
- **Automation:** Boot configurations can be updated via API (updating SMD/BSS) rather than file system changes.
- **Status Tracking:** BSS can receive callbacks from nodes to track boot progress.

### Negative
- **Dependency:** Booting nodes strictly depend on the BSS API being available.
- **Latency:** Adds an API round-trip to the critical boot path.
