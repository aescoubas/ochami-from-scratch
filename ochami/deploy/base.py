from __future__ import annotations

from abc import ABC, abstractmethod

from ochami.config import DeployConfig


class BaseDeployer(ABC):
    def run(self, config: DeployConfig, dry_run: bool = False) -> None:
        self.validate(config)
        host_ip = self.configure_network(config, dry_run=dry_run)
        self.deploy(config, host_ip=host_ip, dry_run=dry_run)
        self.post_deploy(config, host_ip=host_ip, dry_run=dry_run)

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
