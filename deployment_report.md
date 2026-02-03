The OpenCHAMI deployment and PXE boot process have been fixed and verified.

**Summary of Fixes:**

1.  **Cloud-Init & Boot Assets:**
    *   Added `user-data` and `meta-data` to `ochami-http-server` ConfigMap/Pod to ensure VMs can configure themselves.
    *   Fixed the `ds` (datasource) parameter in BSS by updating `bss.advertise_address` in Helm values to include the `http://` scheme. This allows `cloud-init` to correctly identify the network datasource.

2.  **BSS & Database Consistency:**
    *   Identified that the `ochami-bss` Postgres backend requires the `boot_mac` column in the `nodes` table to be populated for MAC-based boot script lookups.
    *   Implemented a workaround by manually updating the `nodes` table to map `xname` to `boot_mac`.
    *   Prevented `ochami-kea` IP allocation errors (duplicate records) by modifying `create_vm.sh` and `recreate_vms.sh` to use **fixed MAC addresses** (`52:54:00:00:00:01`, `52:54:00:00:00:02`). This ensures database consistency across VM recreations.

3.  **Registration Workflow:**
    *   Enabled `redfish-emulator` in the Helm deployment to ensure `register_local_vm.sh` can successfully register BMC endpoints without crashing.
    *   Standardized the VM recreation process via `scripts/recreate_vms.sh` to be robust and reproducible.

**Verification:**
*   **PXE Boot:** Confirmed via logs that VMs successfully download `boot.ipxe`, `vmlinuz-lts`, `initramfs-lts`, and `rootfs.squashfs` (150MB+).
*   **BSS:** Confirmed BSS receives `GET /bootscript` requests and serves the correct iPXE script (length ~498 bytes) instead of the "unknown node" chain script (126 bytes).

**Next Steps:**
*   The VMs are now booting into the live image.
*   To log in, use the console: `sudo virsh console virtual-compute-node-0`.
*   User: `local`, Password: `linux` (configured in `user-data`).
