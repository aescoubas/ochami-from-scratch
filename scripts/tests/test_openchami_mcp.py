#!/usr/bin/env python3
import importlib.util
import json
import pathlib
import sys
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
API_MODULE_PATH = PROJECT_ROOT / "scripts/mcp/openchami_api.py"
SERVER_MODULE_PATH = PROJECT_ROOT / "scripts/mcp/openchami_mcp_server.py"


def load_module(path: pathlib.Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class FakeApiClient:
    def __init__(self, responses=None):
        self.calls = []
        self.responses = responses or {}

    def request(self, method, path, payload=None, timeout=None):
        key = (method, path)
        self.calls.append((method, path, payload, timeout))
        if key in self.responses:
            return self.responses[key]
        return {"ok": True}


class TestOpenChamiMcpServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api_module = load_module(API_MODULE_PATH, "openchami_api")
        cls.server_module = load_module(SERVER_MODULE_PATH, "openchami_mcp_server")

    def test_api_build_url_normalizes_slashes(self):
        client = self.api_module.OpenChamiApiClient("http://127.0.0.1:30080/")
        self.assertEqual(
            client.build_url("/hsm/v2/service/ready"),
            "http://127.0.0.1:30080/hsm/v2/service/ready",
        )
        self.assertEqual(
            client.build_url("boot/v1/service/status"),
            "http://127.0.0.1:30080/boot/v1/service/status",
        )

    def test_read_only_mode_blocks_write_tool(self):
        server = self.server_module.OpenChamiMcpServer(
            api_client=FakeApiClient(),
            mode=self.server_module.READ_ONLY_MODE,
            require_write_ack=False,
        )
        with self.assertRaises(PermissionError):
            server.call_tool(
                "pcs_transition",
                {"xnames": ["x0c0s0b0n0"], "operation": "on"},
            )

    def test_read_write_mode_allows_power_transition(self):
        fake_api = FakeApiClient(
            responses={
                ("POST", "/power-control/v1/transitions"): {"transitionID": "abc-123"}
            }
        )
        server = self.server_module.OpenChamiMcpServer(
            api_client=fake_api,
            mode=self.server_module.READ_WRITE_MODE,
            require_write_ack=False,
        )
        result = server.call_tool(
            "pcs_transition",
            {"xnames": ["x0c0s0b0n0"], "operation": "on"},
        )
        self.assertEqual(fake_api.calls[0][0], "POST")
        self.assertEqual(fake_api.calls[0][1], "/power-control/v1/transitions")
        payload = fake_api.calls[0][2]
        self.assertEqual(payload["operation"], "on")
        self.assertEqual(payload["location"][0]["xname"], "x0c0s0b0n0")
        body = json.loads(result["content"][0]["text"])
        self.assertEqual(body["transitionID"], "abc-123")

    def test_read_tool_group_list_uses_hsm_route(self):
        fake_api = FakeApiClient(
            responses={
                ("GET", "/hsm/v2/groups"): {"groups": [{"label": "test"}]}
            }
        )
        server = self.server_module.OpenChamiMcpServer(
            api_client=fake_api,
            mode=self.server_module.READ_ONLY_MODE,
            require_write_ack=False,
        )
        result = server.call_tool("hsm_list_groups", {})
        self.assertEqual(fake_api.calls[0][0], "GET")
        self.assertEqual(fake_api.calls[0][1], "/hsm/v2/groups")
        self.assertEqual(
            json.loads(result["content"][0]["text"])["groups"][0]["label"], "test"
        )

    def test_tools_list_contains_read_and_write_tools(self):
        server = self.server_module.OpenChamiMcpServer(
            api_client=FakeApiClient(),
            mode=self.server_module.READ_ONLY_MODE,
            require_write_ack=False,
        )
        tools = server.list_tools()
        names = {tool["name"] for tool in tools}
        self.assertIn("openchami_health", names)
        self.assertIn("hsm_list_components", names)
        self.assertIn("hsm_list_groups", names)
        self.assertIn("pcs_transition", names)
        self.assertIn("hsm_create_group", names)


if __name__ == "__main__":
    unittest.main()
