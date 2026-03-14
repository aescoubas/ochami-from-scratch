# OpenCHAMI Agent Guidelines

## Context
*   **Service definitions (single source of truth):** `nix/services/*.nix`
*   **Artifact generators:** `nix/generators/*.nix` (docker-compose, quadlets, helm-values)
*   **OCI image builds:** `nix/images/*.nix`
*   **Deploy profile:** `nix/deploy/profile.nix` (systemd unit generator)
*   **Operational scripts:** `scripts/ops/` (bash — deploy, teardown, health-check, etc.)
*   **MCP server:** `ochami/mcp/` (standalone Python, stdlib only)
*   **Helm chart:** `ochami-helm/` (templates + values)
*   **NixOS VM lab:** `nix/lab/` + `nix/tests/lab-smoke.nix`
*   **Boot artifacts:** `nix/boot-artifacts.nix`
*   **Docs:** `README.md`, `AGENTS.md`, `docs/architecture/`, `docs/plans/ROADMAP.md`
*   **Tests:** `tests/` (pytest via `make test`)

## Architecture
*   `nix/services/defaults.nix` is the shared constants file (ports, images, databases, secrets).
*   All deployment artifacts (docker-compose.yml, .container files, values.yaml) are **generated** from `nix/services/*.nix` via `nix/generators/*.nix`.
*   PXE/iPXE boot payloads are built by `nix/boot-artifacts.nix` and consumed by the local runtime.
*   Runtime operations (deploy, teardown, health checks, node registration) are handled by bash scripts in `scripts/ops/`.
*   The local Docker Compose PXE lab uses libvirt network `ochami-pxe-net`, bridge `virbr-ochami`, and `scripts/ops/create-test-vms.sh` for test VM bootstrap.
*   Architecture overviews and ADRs belong under `docs/architecture/`, not a top-level `ARCHITECTURE/` directory.
*   The MCP server (`ochami/mcp/`) is self-contained with zero external dependencies (stdlib only).
*   There is no Python CLI — the old `ochamifs` was removed. The only Python entry point is `ochami-mcp`.

## Mandates
1.  **Roadmap Driven:** Always check `docs/plans/ROADMAP.md` before starting work. Mark tasks as `[x]` only after verification.
2.  **Test First:** Create/Update tests before implementing features.
3.  **Nix as Source of Truth:** Service definitions live in `nix/services/*.nix`. Never hand-write docker-compose.yml, .container files, or values.yaml — they are generated.
4.  **Architecture Docs Location:** Keep architecture notes and ADRs under `docs/architecture/`. Do not create or update a top-level `ARCHITECTURE/` directory.
5.  **Style:** Follow existing coding style. Nix files use the patterns in `nix/services/`. Bash scripts use `set -euo pipefail` and source `lib/common.sh`.
6.  **Operational Safety:**
    *   **Non-Interactive:** Use flags to suppress prompts (e.g., `apt-get -y`).
    *   **No Watch Modes:** Never run commands that block forever unless explicitly requested as a background daemon.
7.  **Git:**
    *   **Commit Message Standard:** Use Conventional Commits (`type(scope): description`).
        *   Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.
        *   Example: `feat(generators): add stork profile support to docker-compose generator`
    *   **Descriptive:** The message must clearly explain *what* changed and *why*. Avoid vague messages like "fix".
    *   Never commit broken code.

## Verification
*   Always run the build/test suite before finishing a turn.
*   Command: `make test`
*   Nix builds: `nix build .#docker-compose-yml`, `nix build .#quadlet-units`, `nix build .#deploy-profile`
*   GitHub Actions is out of scope for this repository. Keep verification local unless explicitly requested otherwise.
