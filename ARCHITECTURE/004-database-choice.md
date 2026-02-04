# ADR 004: PostgreSQL as Central Data Store

## Status
Accepted

## Context
Multiple components of the OpenCHAMI stack, including the State Management Daemon (SMD), Boot Script Service (BSS), and Kea DHCP, require persistent storage for structured data (hardware inventory, boot parameters, lease information).

## Decision
We selected **PostgreSQL** as the shared relational database management system.

- **Shared Instance:** A single Postgres instance (deployed via the Helm chart) serves databases for SMD, BSS, and Kea.
- **Initialization:** ConfigMaps are used to initialize the necessary users and databases on startup.

## Consequences
### Positive
- **Reliability:** PostgreSQL is a mature, ACID-compliant database.
- **Integration:** Native support in Kea DHCP and excellent support in the Go (SMD/BSS) ecosystem.
- **Efficiency:** Running a single database instance reduces resource overhead compared to running separate databases for each service in a test environment.

### Negative
- **Single Point of Failure:** If the Postgres instance fails, multiple control plane services (SMD, BSS, DHCP) will be impacted.
- **Coupling:** Shared resource usage requires coordination in configuration (ports, credentials).
