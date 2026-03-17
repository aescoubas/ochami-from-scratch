# ADR 003: State Synchronization via `kea-sync`

## Status
Accepted

## Context
The system needs to maintain consistency between the authoritative hardware inventory in the State Management Database (SMD) and the network configuration used by the Kea DHCP server. Specifically, when a node is assigned a static IP in SMD, Kea needs to be updated to reserve that IP for the node's MAC address.

## Decision
We synchronize state with the dedicated `kea-sync` Go service.

- **Mechanism:** `kea-sync` periodically polls the SMD API for registered interfaces and components.
- **Action:** It reconciles desired reservations into Kea through Kea's native HTTP control sockets and host commands instead of writing PostgreSQL tables directly.
- **Replacement:** This replaces both the legacy `coresmd` plugin approach and the earlier ad hoc Python sidecar.

## Consequences
### Positive
- **API ownership:** Kea remains the authority for its own reservation mutations through supported APIs.
- **Safer reconciliation:** `kea-sync` manages only reservations it tags as OpenCHAMI-managed, reducing drift risk for manual entries.
- **Operational clarity:** Health, readiness, metrics, and explicit sync endpoints make the integration easier to observe and debug.

### Negative
- **Latency:** There is a delay (polling interval) between a change in SMD and its reflection in DHCP.
- **Extra runtime dependency:** Kea's HTTP control sockets and host command hooks must be enabled for reconciliation to work.
