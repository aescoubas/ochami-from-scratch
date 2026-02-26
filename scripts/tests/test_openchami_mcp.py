#!/usr/bin/env python3
import io
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


class FakeStdio:
    def __init__(self, payload: bytes = b""):
        self.buffer = io.BytesIO(payload)


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

    def test_read_only_mode_blocks_bss_write_tools(self):
        server = self.server_module.OpenChamiMcpServer(
            api_client=FakeApiClient(),
            mode=self.server_module.READ_ONLY_MODE,
            require_write_ack=False,
        )
        write_tools = [
            ("bss_put_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}}),
            ("bss_post_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}}),
            ("bss_patch_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}}),
            ("bss_delete_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}}),
            ("bss_hosts_post", {"payload": {"id": "x0c0s0b0n0"}}),
        ]
        for tool_name, args in write_tools:
            with self.subTest(tool=tool_name):
                with self.assertRaises(PermissionError):
                    server.call_tool(tool_name, args)

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

    def test_read_write_mode_allows_bss_writes(self):
        fake_api = FakeApiClient(
            responses={
                ("PUT", "/boot/v1/bootparameters"): {"ok": "put"},
                ("POST", "/boot/v1/bootparameters"): {"ok": "post"},
                ("PATCH", "/boot/v1/bootparameters"): {"ok": "patch"},
                ("DELETE", "/boot/v1/bootparameters"): {"ok": "delete"},
                ("POST", "/boot/v1/hosts"): {"ok": "hosts-post"},
            }
        )
        server = self.server_module.OpenChamiMcpServer(
            api_client=fake_api,
            mode=self.server_module.READ_WRITE_MODE,
            require_write_ack=False,
        )

        server.call_tool("bss_put_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}})
        server.call_tool("bss_post_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}})
        server.call_tool("bss_patch_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}})
        server.call_tool("bss_delete_bootparameters", {"payload": {"hosts": ["x0c0s0b0n0"]}})
        server.call_tool("bss_hosts_post", {"payload": {"id": "x0c0s0b0n0"}})

        self.assertEqual(fake_api.calls[0][0], "PUT")
        self.assertEqual(fake_api.calls[0][1], "/boot/v1/bootparameters")
        self.assertEqual(fake_api.calls[1][0], "POST")
        self.assertEqual(fake_api.calls[1][1], "/boot/v1/bootparameters")
        self.assertEqual(fake_api.calls[2][0], "PATCH")
        self.assertEqual(fake_api.calls[2][1], "/boot/v1/bootparameters")
        self.assertEqual(fake_api.calls[3][0], "DELETE")
        self.assertEqual(fake_api.calls[3][1], "/boot/v1/bootparameters")
        self.assertEqual(fake_api.calls[4][0], "POST")
        self.assertEqual(fake_api.calls[4][1], "/boot/v1/hosts")

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

    def test_bss_read_tools_use_expected_routes(self):
        fake_api = FakeApiClient(
            responses={
                ("GET", "/boot/v1/service/status"): {"status": "ready"},
                ("GET", "/boot/v1/bootparameters"): {"boot_params": []},
                ("GET", "/boot/v1/bootscript?mac=00%3A11%3A22%3A33%3A44%3A55"): {"script": "#!ipxe"},
                ("GET", "/boot/v1/hosts"): {"hosts": []},
            }
        )
        server = self.server_module.OpenChamiMcpServer(
            api_client=fake_api,
            mode=self.server_module.READ_ONLY_MODE,
            require_write_ack=False,
        )

        server.call_tool("bss_service_status", {})
        server.call_tool("bss_get_bootparameters", {})
        server.call_tool("bss_get_bootscript", {"mac": "00:11:22:33:44:55"})
        server.call_tool("bss_list_hosts", {})

        self.assertEqual(fake_api.calls[0][0], "GET")
        self.assertEqual(fake_api.calls[0][1], "/boot/v1/service/status")
        self.assertEqual(fake_api.calls[1][0], "GET")
        self.assertEqual(fake_api.calls[1][1], "/boot/v1/bootparameters")
        self.assertEqual(fake_api.calls[2][0], "GET")
        self.assertEqual(
            fake_api.calls[2][1],
            "/boot/v1/bootscript?mac=00%3A11%3A22%3A33%3A44%3A55",
        )
        self.assertEqual(fake_api.calls[3][0], "GET")
        self.assertEqual(fake_api.calls[3][1], "/boot/v1/hosts")

    def test_bss_get_bootscript_requires_selector(self):
        server = self.server_module.OpenChamiMcpServer(
            api_client=FakeApiClient(),
            mode=self.server_module.READ_ONLY_MODE,
            require_write_ack=False,
        )
        with self.assertRaises(ValueError):
            server.call_tool("bss_get_bootscript", {})

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
        self.assertIn("bss_get_bootscript", names)
        self.assertIn("bss_delete_bootparameters", names)
        self.assertIn("bss_hosts_post", names)

    def test_stdio_jsonl_framing_round_trip(self):
        framing_state = {}
        request_line = (
            json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "clientInfo": {"name": "probe", "version": "0.1.0"},
                    },
                }
            )
            + "\n"
        ).encode("utf-8")
        stdin = FakeStdio(request_line)

        request = self.server_module.read_jsonrpc_message(stdin, framing_state)
        self.assertEqual(request["method"], "initialize")
        self.assertEqual(framing_state["mode"], self.server_module.FRAMING_JSONL)

        stdout = FakeStdio()
        self.server_module.write_jsonrpc_message(
            stdout,
            {"jsonrpc": "2.0", "id": 1, "result": {}},
            framing_state,
        )
        out_bytes = stdout.buffer.getvalue()
        self.assertTrue(out_bytes.endswith(b"\n"))
        self.assertNotIn(b"Content-Length:", out_bytes)

    def test_stdio_content_length_framing_round_trip(self):
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "probe", "version": "0.1.0"},
                },
            },
            separators=(",", ":"),
        ).encode("utf-8")
        framed = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
        framing_state = {}
        stdin = FakeStdio(framed)

        request = self.server_module.read_jsonrpc_message(stdin, framing_state)
        self.assertEqual(request["method"], "initialize")
        self.assertEqual(
            framing_state["mode"], self.server_module.FRAMING_CONTENT_LENGTH
        )

        stdout = FakeStdio()
        self.server_module.write_jsonrpc_message(
            stdout,
            {"jsonrpc": "2.0", "id": 1, "result": {}},
            framing_state,
        )
        out_bytes = stdout.buffer.getvalue()
        self.assertTrue(out_bytes.startswith(b"Content-Length:"))


if __name__ == "__main__":
    unittest.main()
