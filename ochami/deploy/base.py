from __future__ import annotations

from abc import ABC, abstractmethod
from datetime import datetime, timezone
from pathlib import Path

from ochami.config import DeployConfig
from ochami.state import AppliedState, config_hash, load_state, needs_apply, save_state


class BaseDeployer(ABC):
    def run(self, config: DeployConfig, dry_run: bool = False) -> None:
        self.validate(config)
        host_ip = self.configure_network(config, dry_run=dry_run)
        self.deploy(config, host_ip=host_ip, dry_run=dry_run)
        self.post_deploy(config, host_ip=host_ip, dry_run=dry_run)

    def apply(
        self,
        config: DeployConfig,
        *,
        state_path: Path,
        force: bool = False,
        dry_run: bool = False,
    ) -> None:
        self.validate(config)
        current = config_hash(config)
        saved = load_state(state_path)
        if not force and not needs_apply(current, saved):
            self.ensure_healthy(config, dry_run=dry_run)
            return
        host_ip = self.configure_network(config, dry_run=dry_run)
        self.deploy(config, host_ip=host_ip, dry_run=dry_run)
        self.post_deploy(config, host_ip=host_ip, dry_run=dry_run)
        if not dry_run:
            save_state(
                state_path,
                AppliedState(
                    config_hash=current,
                    method=config.method.value,
                    timestamp=datetime.now(timezone.utc).isoformat(),
                ),
            )

    def ensure_healthy(self, config: DeployConfig, dry_run: bool = False) -> None:
        """Lightweight health check — overridden by subclasses."""

    def validate(self, config: DeployConfig) -> None:
        config.validate()

    @abstractmethod
    def configure_network(self, config: DeployConfig, dry_run: bool) -> str:
        raise NotImplementedError

    @abstractmethod
    def deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        raise NotImplementedError

    @abstractmethod
    def post_deploy(self, config: DeployConfig, host_ip: str, dry_run: bool) -> None:
        raise NotImplementedError
