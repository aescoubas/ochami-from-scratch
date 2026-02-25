# OpenCHAMI From Scratch Roadmap

## In Progress
- [x] Remove production TODO grace-period behavior in Helm pod templates (`smd`, `bss`, `pcs`) by making the value configurable and production-safe by default.
- [x] Deduplicate deploy lifecycle orchestration across Minikube, Quadlets, and Docker Compose using shared pipeline helpers.
  - [x] `scripts/deploy/minikube.sh`, `scripts/deploy/quadlets.sh`, and `scripts/deploy/docker-compose.sh` call shared lifecycle functions from `scripts/deploy/lib/pipeline.sh`.
  - [x] Shared helpers cover common bootstrap, prerequisites install, and post-deploy discovery/VM flow.
- [x] Deduplicate Quadlets and Docker Compose runtime env/template generation with shared helpers.
  - [x] Both deploy methods source `scripts/deploy/lib/runtime_config.sh`.
  - [x] Both methods use shared env exports and template rendering helpers.

## Completed
- [x] Make `fs.protected_regular` mutation opt-in and restore only when managed by OpenCHAMI.
- [x] Enforce roadmap process contract by keeping `ROADMAP.md` at repo root and adding a regression test guard in `make test`.
- [x] Remove CI automation requirement from project process docs and keep GitHub Actions out of scope by default.
