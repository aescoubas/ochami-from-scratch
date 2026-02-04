# ADR 003: State Synchronization via Sidecar Pattern

## Status
Accepted

## Context
The system needs to maintain consistency between the authoritative hardware inventory in the State Management Database (SMD) and the network configuration used by the Kea DHCP server. Specifically, when a node is assigned a static IP in SMD, Kea needs to be updated to reserve that IP for the node's MAC address.

## Decision
We implemented a **Sidecar Pattern** to synchronize state. A Python script runs in a sidecar container within the same Pod as the Kea DHCP server.

- **Mechanism:** The sidecar periodically polls the SMD API for registered interfaces.
- **Action:** When changes are detected, it updates Kea's local PostgreSQL backend (specifically the `hosts` table) to create or update reservations.
- **Replacement:** This replaces the legacy `coresmd` plugin approach.

## Consequences
### Positive
- **Decoupling:** The DHCP server does not need to know about the internal logic or existence of SMD directly; it just reads from its own database.
- **Reliability:** If SMD goes down, Kea continues to serve existing reservations from its local database.
- **Simplicity:** Easier to implement and debug a polling script than a complex hook or plugin within the DHCP server's process.

### Negative
- **Latency:** There is a delay (polling interval) between a change in SMD and its reflection in DHCP.
- **Duplication:** Data is effectively duplicated between SMD and Kea's database, requiring careful management to avoid drift if the sync fails.
