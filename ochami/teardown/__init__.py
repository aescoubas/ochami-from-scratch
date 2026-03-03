"""Teardown implementations."""

from ochami.teardown.compose import ComposeTeardown
from ochami.teardown.minikube import MinikubeTeardown
from ochami.teardown.quadlets import QuadletsTeardown

__all__ = ["ComposeTeardown", "QuadletsTeardown", "MinikubeTeardown"]
