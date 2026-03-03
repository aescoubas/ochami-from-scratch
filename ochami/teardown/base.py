from __future__ import annotations

from abc import ABC, abstractmethod

from ochami.config import TeardownConfig


class BaseTeardown(ABC):
    def run(self, config: TeardownConfig, dry_run: bool = False) -> None:
        self.validate(config)
        self.teardown(config, dry_run=dry_run)

    def validate(self, config: TeardownConfig) -> None:
        config.validate()

    @abstractmethod
    def teardown(self, config: TeardownConfig, dry_run: bool) -> None:
        raise NotImplementedError
