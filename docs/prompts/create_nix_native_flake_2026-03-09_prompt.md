# Create Nix Native Flake Prompt

```text
Read AGENTS.md and any roadmap/instructions first and follow them.

I want this repo to own a Nix-native build.

This repo appears to be a Python CLI / operations tool (`pyproject.toml`) with external orchestration targets like minikube, quadlets, and docker-compose.

Please:
1. Inspect the current packaging and test flow before editing.
2. Create a minimal `flake.nix` and any supporting files under `nix/`.
3. Export at least:
   - `packages.<system>.default`: the Python CLI package
   - `apps.<system>.default`: runnable CLI entrypoint
   - `checks.<system>.default`: meaningful checks
   - `devShells.<system>.default`: a practical dev shell
4. Package the Python CLI natively with Nix.
5. Do not try to package the entire external runtime stack inside the main package output. The flake should package the tool cleanly first.
6. Preserve current CLI behavior and entrypoints.
7. Update README with:
   - `nix develop`
   - `nix build`
   - `nix run`
   - `nix flake check`
8. Run the repo's existing tests/checks and `nix flake check` before finishing.

Keep the flake minimal and production-usable.
```
