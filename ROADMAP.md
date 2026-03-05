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
- [x] Default deploy behavior now temporarily adjusts `fs.protected_regular` without requiring explicit user opt-in.
  - [x] Set `DeployConfig.set_fs_protected_regular` default to `true`.
  - [x] Update deploy CLI to default-enable the behavior and expose `--no-set-fs-protected-regular` opt-out.
  - [x] Add/adjust regression tests for CLI and deployer defaults.
- [x] Auto-recover from Minikube none-driver lock permission failures without requiring explicit `--set-fs-protected-regular`.
  - [x] Retry Minikube start once after lowering `fs.protected_regular` only for the known lock-related exit code path.
  - [x] Persist previous kernel value so teardown can restore it.
  - [x] Add regression tests for retry and non-applicable failure paths.
- [x] Require explicit `--method` for `ochami deploy` and `ochami teardown` to avoid implicit default orchestrator selection.
  - [x] Remove default deployment method in both CLI commands so Typer enforces `--method`.
  - [x] Add CLI regression tests for missing `--method` on deploy and teardown.
- [x] Complete Python CLI migration cleanup (Phase 6) by removing legacy shell entrypoints and script directory.
  - [x] Remove `deploy.sh`, `teardown.sh`, and `scripts/`.
  - [x] Update `Makefile` so `make test` runs pytest.
  - [x] Update README usage to Python CLI commands (`ochami ...`).
  - [x] Keep deployment artifact directories (`ochami-docker-compose/`, `ochami-helm/`, `ochami-quadlets/`).
- [x] Make `fs.protected_regular` mutation opt-in and restore only when managed by OpenCHAMI.
- [x] Enforce roadmap process contract by keeping `ROADMAP.md` at repo root and adding a regression test guard in `make test`.
- [x] Remove CI automation requirement from project process docs and keep GitHub Actions out of scope by default.
- [x] Make libvirt VM runner network activation idempotent/race-safe when `default` is already active.
  - [x] Add regression tests for already-active, inactive-start, race-on-start, and persistent-failure scenarios using mocked `virsh`.
  - [x] Refactor `libvirt/scripts/vm_tests.sh` network startup flow and add diagnostics for unrecoverable failures.
