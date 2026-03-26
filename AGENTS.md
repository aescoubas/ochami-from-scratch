# OpenCHAMI Agent Guidelines

## Context
*   **OCI image builds:** `images/<service>/Dockerfile` (built via buildah/docker)
*   **Deployment artifacts:** `deploy/compose/`, `deploy/quadlets/`, `deploy/helm/`
*   **Deployment profiles:** `profiles/*.env` (official, dev, cscs)
*   **Operational scripts:** `scripts/ops/` (bash -- deploy, teardown, health-check, push-images, load-images, etc.)
*   **RPM packaging:** `ochami-from-scratch.spec` + `Makefile` rpm targets
*   **MCP server:** `ochami/mcp/` (standalone Python, stdlib only)
*   **Docs:** `README.md`, `AGENTS.md`, `docs/architecture/`, `docs/plans/ROADMAP.md`
*   **Tests:** `tests/` (pytest via `make test`)

## Architecture
*   OCI images are built from Dockerfiles in `images/<service>/Dockerfile` using buildah or docker.
*   Deployment profiles (`profiles/*.env`) define version refs, image prefix, and optional registry. Available profiles: `official` (default, `localhost/*`), `dev` (moving main refs), `cscs` (CSCS JFrog, `cscs-` prefix).
*   Deployment artifacts (docker-compose.yml, .container files, values.yaml) are directly maintained in `deploy/`.
*   Runtime configs require secret interpolation at deploy/activation time via `envsubst`; config templates keep placeholders until deploy time.
*   Runtime operations (deploy, teardown, health checks, node registration) are handled by bash scripts in `scripts/ops/`.
*   The local Docker Compose PXE lab uses libvirt network `ochami-pxe-net`, bridge `virbr-ochami`, and `scripts/ops/create-test-vms.sh` for test VM bootstrap.
*   Local OCI image builds are orchestrated by `scripts/ops/build-images.sh`; `make build-images` and `make deploy` accept `SMD_SRC`, `BSS_SRC`, `PCS_SRC`, `CLOUD_INIT_SRC`, and `KEA_SYNC_SRC` to build specific services from local checkouts.
*   `make teardown METHOD=compose` removes compose containers and volumes and restores paused libvirt DHCP networks, but it does **not** delete libvirt test VMs or their qcow2 disks.
*   Architecture overviews and ADRs belong under `docs/architecture/`, not a top-level `ARCHITECTURE/` directory.
*   The MCP server (`ochami/mcp/`) is self-contained with zero external dependencies (stdlib only).
*   There is no Python CLI -- the old `ochamifs` was removed. The only Python entry point is `ochami-mcp`.
*   Three deployment methods are supported: `compose`, `quadlets`, and `minikube`.

## Mandates
1.  **Roadmap Driven:** Always check `docs/plans/ROADMAP.md` before starting work. Mark tasks as `[x]` only after verification.
2.  **Test First:** Create/Update tests before implementing features.
3.  **Architecture Docs Location:** Keep architecture notes and ADRs under `docs/architecture/`. Do not create or update a top-level `ARCHITECTURE/` directory.
4.  **Style:** Follow existing coding style. Bash scripts use `set -euo pipefail` and source `lib/common.sh`.
5.  **Operational Safety:**
    *   **Non-Interactive:** Use flags to suppress prompts (e.g., `apt-get -y`).
    *   **No Watch Modes:** Never run commands that block forever unless explicitly requested as a background daemon.
    *   **Compose PXE Host Assumptions:** The compose PXE path expects host tools such as Docker, libvirt, `envsubst`, and passwordless `sudo` for bridge/libvirt network preparation.
6.  **Git:**
    *   **Commit Message Standard:** Use Conventional Commits (`type(scope): description`).
        *   Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.
        *   Example: `feat(generators): add stork profile support to docker-compose generator`
    *   **Descriptive:** The message must clearly explain *what* changed and *why*. Avoid vague messages like "fix".
    *   Never commit broken code.

## Verification
*   Always run the build/test suite before finishing a turn.
*   Command: `make test`
*   Image builds: `make build-images` or `make build-images PROFILE=cscs`
*   RPM packaging: `make rpm` (official) or `make rpm PROFILE=cscs` (CSCS JFrog)
*   GitHub Actions is out of scope for this repository. Keep verification local unless explicitly requested otherwise.
