# OpenCHAMI From Scratch Roadmap

## In Progress
- [x] Remove production TODO grace-period behavior in Helm pod templates (`smd`, `bss`, `pcs`) by making the value configurable and production-safe by default.

## Completed
- [x] Make `fs.protected_regular` mutation opt-in and restore only when managed by OpenCHAMI.
- [x] Enforce roadmap process contract by keeping `ROADMAP.md` at repo root and adding a regression test guard in `make test`.
