from __future__ import annotations

from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_helm_kea_config_uses_direct_http_control_sockets() -> None:
    """Helm Kea config should expose HTTP control directly from the DHCP server."""
    configmap = (PROJECT_ROOT / "ochami-helm" / "templates" / "kea-configmap.yaml").read_text(encoding="utf-8")

    assert '"control-sockets": [' in configmap
    assert '"socket-type": "http"' in configmap
    assert '"socket-address": "127.0.0.1"' in configmap
    assert '"socket-port": {{ .Values.kea.controlPort }}' in configmap
    assert "kea-ctrl-agent.conf" not in configmap


def test_helm_kea_pod_removes_control_agent_sidecar() -> None:
    """Helm Kea pod should not run a separate control-agent sidecar."""
    pod = (PROJECT_ROOT / "ochami-helm" / "templates" / "kea-pod.yaml").read_text(encoding="utf-8")

    assert 'value: "http://127.0.0.1:{{ .Values.kea.controlPort }}"' in pod
    assert 'value: "dhcp4"' in pod
    assert "- name: kea-ctrl-agent" not in pod
    assert "kea-ctrl-agent.conf" not in pod
