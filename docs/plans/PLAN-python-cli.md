# Plan: Migrate Bash Orchestration to Python CLI

## Motivation

The repository has ~5,000 lines of bash across ~30 files. `common.sh` alone is 1,596 lines
handling arg parsing, validation, config defaults, deployment helpers, and teardown logic.
The deduplication work (`pipeline.sh`, `runtime_config.sh`) is solid, but bash is the wrong
tool at this scale — poor testability, no types, fragile string handling, `set -e` footguns.

A Python CLI with Typer eliminates ~1,800 lines of glue code (arg parsing, validation, help
text), replaces `envsubst` with Jinja2 templating, and enables real pytest-based testing.

## Target Structure

```
ochami-from-scratch/
├── ochami/                     # Python package
│   ├── __init__.py
│   ├── cli.py                  # Typer app: deploy / teardown / status commands
│   ├── config.py               # Dataclass with all settings (replaces common.sh defaults)
│   ├── deploy/
│   │   ├── __init__.py
│   │   ├── base.py             # Abstract deployer with shared lifecycle
│   │   ├── compose.py          # Docker Compose deployer
│   │   ├── quadlets.py         # Podman Quadlets deployer
│   │   └── minikube.py         # Minikube / Helm deployer
│   ├── teardown/
│   │   ├── __init__.py
│   │   ├── base.py             # Abstract teardown with shared lifecycle
│   │   ├── compose.py
│   │   ├── quadlets.py
│   │   └── minikube.py
│   ├── network.py              # Libvirt, PXE, firewall helpers
│   ├── registry.py             # SMD / BSS API calls, hardware registration
│   ├── templates.py            # Jinja2 rendering (replaces envsubst)
│   └── utils.py                # IP math, MAC validation, logging, subprocess wrappers
├── templates/                  # Jinja2 templates (migrated from .template files)
├── tests/                      # pytest (replaces 23 bash test scripts)
│   ├── conftest.py
│   ├── test_config.py
│   ├── test_cli.py
│   ├── test_deploy_compose.py
│   ├── test_deploy_quadlets.py
│   ├── test_deploy_minikube.py
│   ├── test_network.py
│   ├── test_registry.py
│   └── test_templates.py
├── ochami-docker-compose/      # Unchanged
├── ochami-helm/                # Unchanged
├── ochami-quadlets/            # Unchanged
└── pyproject.toml              # pip install -e . → `ochami` CLI entry point
```

## Design Decisions

### Config as a dataclass

All ~30 runtime variables currently scattered across `common.sh` defaults, CLI flags, and
environment variables become a single typed `DeployConfig` dataclass. Validation happens at
construction time via `__post_init__` or a dedicated `validate()` method. This replaces
`parse_common_deploy_args` (96 lines) + `validate_common_deploy_args` (93 lines) entirely.

```python
@dataclass
class DeployConfig:
    method: Literal["minikube", "quadlets", "docker-compose"]
    pxe_interface: str = "eth0"
    cluster_name: str = "ochami"
    host_ip: str = ""           # auto-detected if empty
    subnet: str = "172.16.0.0"
    cidr: int = 20
    db_password: str = ""       # generated if empty
    # ... remaining vars with types and defaults
```

### Deployer base class with shared lifecycle

The 3 deployment methods share a common lifecycle (already factored into `pipeline.sh`).
This becomes an abstract base class:

```python
class BaseDeployer(ABC):
    def run(self, config: DeployConfig):
        self.validate(config)
        self.install_prerequisites(config)
        self.build_images(config)
        self.configure_network(config)
        self.deploy(config)           # abstract — each method implements this
        self.post_deploy(config)      # shared: VM creation, hardware registration

    @abstractmethod
    def deploy(self, config: DeployConfig): ...
```

### Jinja2 replaces envsubst

The `.template` files in `ochami-docker-compose/configs/` and the `export_runtime_template_vars`
+ `envsubst` pipeline become Jinja2 templates rendered against the config dataclass. This gives
us conditionals, loops, defaults, and filters — no more shell variable escaping issues.

### Subprocess wrappers, not SDKs

The deployment logic calls `docker compose`, `podman`, `helm`, `virsh`, `systemctl`, etc.
We wrap these in a thin `run()` helper that handles logging, error messages, and dry-run mode.
We are not replacing these tools, just orchestrating them more cleanly.

### Typer for the CLI

Typer gives us typed arguments, auto-generated `--help`, shell completion, and sub-commands
with minimal boilerplate. The entire arg parsing + help text (~200 lines of bash) becomes
~30 lines of Python.

```python
@app.command()
def deploy(
    method: Method = typer.Option(Method.docker_compose, help="Deployment method"),
    pxe_interface: str = typer.Option("eth0", help="PXE boot interface"),
    cluster_name: str = typer.Option("ochami", help="Cluster name"),
    dry_run: bool = typer.Option(False, help="Show what would be done"),
):
    config = DeployConfig(method=method, pxe_interface=pxe_interface, ...)
    get_deployer(method).run(config)
```

## Migration Phases

Each phase produces a working system. The Python CLI wraps existing bash initially, then
gradually replaces it.

### Phase 1 — Scaffolding and bridge (bash still does all the work)

**Goal:** Python CLI exists, parses args, delegates to existing bash scripts via subprocess.

- [x] Create `pyproject.toml` with Typer, Jinja2, pytest dependencies
- [x] Create `ochami/__init__.py`, `ochami/cli.py` with deploy/teardown sub-commands
- [x] Create `ochami/config.py` with `DeployConfig` dataclass and all defaults
- [x] CLI constructs config, exports env vars, calls `./deploy.sh` / `./teardown.sh`
- [x] Write `tests/test_config.py` — validate defaults, type checking, validation errors
- [x] Write `tests/test_cli.py` — verify CLI arg parsing maps to config correctly
- [x] Verify: `pip install -e .` then `ochami deploy --method docker-compose` works (validated via `--dry-run` bridge execution)

### Phase 2 — Port Docker Compose method (simplest target)

**Goal:** `ochami deploy --method docker-compose` runs entirely in Python. Bash path still
works for minikube and quadlets.

- [x] Create `ochami/utils.py` — `run()` subprocess wrapper, logging, IP/MAC validation
- [x] Create `ochami/templates.py` — Jinja2 rendering against config dataclass
- [x] Migrate `.template` files to `templates/` as Jinja2 templates
- [x] Create `ochami/deploy/base.py` with `BaseDeployer` lifecycle
- [x] Create `ochami/deploy/compose.py` implementing Docker Compose deployment:
  - `.env` generation
  - Config file rendering
  - `docker compose up -d`
- [x] Create `ochami/network.py` — PXE interface config, bridge setup, firewall
- [x] Create `ochami/registry.py` — SMD/BSS API calls, hardware node registration
- [x] Create `ochami/teardown/compose.py`
- [x] Write `tests/test_deploy_compose.py` — mock subprocess, verify correct commands issued
- [x] Write `tests/test_templates.py` — verify rendered output against known-good snapshots
- [x] Verify: full docker-compose deploy + teardown cycle works via Python CLI (validated live on March 3, 2026)

### Phase 3 — Port Quadlets method

**Goal:** `ochami deploy --method quadlets` runs entirely in Python.

- [x] Create `ochami/deploy/quadlets.py`:
  - `/etc/openchami/` env file generation
  - Systemd unit rendering and installation
  - `systemctl` start/enable calls
- [x] Create `ochami/teardown/quadlets.py`
- [x] Write `tests/test_deploy_quadlets.py`
- [x] Verify: full quadlets deploy + teardown cycle works via Python CLI (validated live on March 3, 2026)

### Phase 4 — Port Minikube method

**Goal:** `ochami deploy --method minikube` runs entirely in Python. This is the most complex
due to `minikube`, `kubectl`, and `helm` interactions.

- [x] Create `ochami/deploy/minikube.py`:
  - Minikube cluster creation and configuration
  - Helm values file generation
  - `helm install` / `helm upgrade`
  - Service endpoint discovery via `kubectl get svc`
- [x] Create `ochami/teardown/minikube.py`
- [x] Write `tests/test_deploy_minikube.py`
- [x] Verify: full minikube deploy + teardown cycle works via Python CLI (validated live on March 3, 2026)

### Phase 5 — Port build and prerequisites logic

**Goal:** Image building and prerequisite installation handled in Python.

- [x] Port `build_microservices.sh` logic (build + retry) to `ochami/build.py`
- [x] Port `build_and_load_images.sh` logic to the deployer classes
- [x] Port `install_prerequisites.sh` to `ochami/prerequisites.py`
- [x] Write corresponding tests

### Phase 6 — Cleanup

**Goal:** Remove bash scripts, update documentation, finalize.

- [x] Remove `deploy.sh`, `teardown.sh`, `scripts/` directory
- [x] Keep `ochami-docker-compose/`, `ochami-helm/`, `ochami-quadlets/` as deployment artifacts
- [x] Update `README.md` with new CLI usage
- [x] Update `ROADMAP.md`
- [x] Update `Makefile` — `make test` runs `pytest`
- [x] Verify: all 3 methods deploy + teardown cleanly (validated live on March 3, 2026)
- [ ] Tag release

## Dependencies

```toml
[project]
requires-python = ">=3.10"
dependencies = [
    "typer>=0.9",
    "jinja2>=3.1",
    "rich>=13.0",       # pretty output (Typer uses this)
]

[project.optional-dependencies]
dev = [
    "pytest>=7.0",
    "pytest-mock>=3.10",
]

[project.scripts]
ochami = "ochami.cli:app"
```

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Python not installed on target hosts | Require Python 3.10+ (ships with most distros since 2022). Document in prerequisites. |
| Behavioral drift during migration | Each phase has a verification step. Keep bash scripts until the Python equivalent is proven. |
| `sudo` interactions (quadlets need root) | `run()` wrapper supports `sudo=True` flag, same as current `$CONTAINER_TOOL` prefix pattern. |
| macOS compatibility (Docker Compose) | Test on macOS in Phase 2. Python's `platform` module replaces `uname` checks. |
| Jinja2 template migration breaks configs | Snapshot tests compare rendered output against current envsubst output before switching. |
