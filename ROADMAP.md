# OpenCHAMI From Scratch Roadmap

## In Progress
- [x] Remove production TODO grace-period behavior in Helm pod templates (`smd`, `bss`, `pcs`) by making the value configurable and production-safe by default.
- [x] Deduplicate deploy lifecycle orchestration across Minikube, Quadlets, and Docker Compose using shared pipeline helpers.
  - [x] `scripts/deploy/minikube.sh`, `scripts/deploy/quadlets.sh`, and `scripts/deploy/docker-compose.sh` call shared lifecycle functions from `scripts/deploy/lib/pipeline.sh`.
  - [x] Shared helpers cover common bootstrap, prerequisites install, and post-deploy discovery/VM flow.
- [x] Deduplicate Quadlets and Docker Compose runtime env/template generation with shared helpers.
  - [x] Both deploy methods source `scripts/deploy/lib/runtime_config.sh`.
  - [x] Both methods use shared env exports and template rendering helpers.
- [x] Add a minimal Python MCP server for local OpenCHAMI control with explicit read-only/read-write modes.
  - [x] Implement MCP tools for health/status, SMD component/group reads, BSS reads/writes, PCS power status, and gated write operations (power transitions + group CRUD/member updates).
  - [x] Integrate usage guidance only in `scripts/deploy/minikube.sh` (no Quadlets/Docker Compose wiring yet).
  - [x] Add regression tests and README usage docs for minikube-only MCP workflow.

## Completed
- [x] Make `fs.protected_regular` mutation opt-in and restore only when managed by OpenCHAMI.
- [x] Enforce roadmap process contract by keeping `ROADMAP.md` at repo root and adding a regression test guard in `make test`.
- [x] Remove CI automation requirement from project process docs and keep GitHub Actions out of scope by default.
- [x] Make libvirt VM runner network activation idempotent/race-safe when `default` is already active.
  - [x] Add regression tests for already-active, inactive-start, race-on-start, and persistent-failure scenarios using mocked `virsh`.
  - [x] Refactor `libvirt/scripts/vm_tests.sh` network startup flow and add diagnostics for unrecoverable failures.
