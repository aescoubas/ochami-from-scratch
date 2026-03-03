#!/usr/bin/env python3
"""Minimal MCP server for controlling a local OpenCHAMI deployment."""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Callable, Dict, Iterable, Optional
from urllib.parse import quote, urlencode

from ochami.mcp.openchami_api import OpenChamiApiClient, OpenChamiApiError


READ_ONLY_MODE = "read-only"
READ_WRITE_MODE = "read-write"
DEFAULT_PROTOCOL_VERSION = "2024-11-05"
TRUE_VALUES = {"1", "true", "yes", "on"}
FRAMING_JSONL = "jsonl"
FRAMING_CONTENT_LENGTH = "content-length"


class OpenChamiMcpServer:
    """MCP tool dispatcher for OpenCHAMI APIs."""

    def __init__(
        self,
        api_client: OpenChamiApiClient,
        mode: str = READ_ONLY_MODE,
        require_write_ack: bool = True,
    ):
        if mode not in {READ_ONLY_MODE, READ_WRITE_MODE}:
            raise ValueError(f"Unsupported mode: {mode}")
        self.api_client = api_client
        self.mode = mode
        self.require_write_ack = require_write_ack
        self._tools = self._build_tool_map()
        self._write_tools = {
            "pcs_transition",
            "hsm_create_group",
            "hsm_delete_group",
            "hsm_update_group_members",
            "bss_put_bootparameters",
            "bss_post_bootparameters",
            "bss_patch_bootparameters",
            "bss_delete_bootparameters",
            "bss_hosts_post",
        }

    def list_tools(self) -> list[Dict[str, Any]]:
        return [
            self._tool_def(
                name="openchami_health",
                description="Check core OpenCHAMI readiness via reverse-proxied endpoints.",
                input_schema={
                    "type": "object",
                    "properties": {
                        "timeout": {"type": "integer", "minimum": 1, "default": 5}
                    },
                },
                read_only=True,
            ),
            self._tool_def(
                name="hsm_list_components",
                description="List all HSM components.",
                input_schema={"type": "object", "properties": {}},
                read_only=True,
            ),
            self._tool_def(
                name="hsm_get_component",
                description="Get a single HSM component by xname.",
                input_schema={
                    "type": "object",
                    "properties": {"xname": {"type": "string"}},
                    "required": ["xname"],
                },
                read_only=True,
            ),
            self._tool_def(
                name="hsm_list_groups",
                description="List HSM groups.",
                input_schema={"type": "object", "properties": {}},
                read_only=True,
            ),
            self._tool_def(
                name="hsm_get_group",
                description="Get an HSM group by label.",
                input_schema={
                    "type": "object",
                    "properties": {"label": {"type": "string"}},
                    "required": ["label"],
                },
                read_only=True,
            ),
            self._tool_def(
                name="pcs_power_status",
                description="Query PCS power status for one or more xnames.",
                input_schema={
                    "type": "object",
                    "properties": {
                        "xnames": {
                            "type": "array",
                            "items": {"type": "string"},
                            "minItems": 1,
                        }
                    },
                    "required": ["xnames"],
                },
                read_only=True,
            ),
            self._tool_def(
                name="bss_service_status",
                description="Get BSS service status.",
                input_schema={"type": "object", "properties": {}},
                read_only=True,
            ),
            self._tool_def(
                name="bss_get_bootparameters",
                description="List BSS boot parameter records.",
                input_schema={"type": "object", "properties": {}},
                read_only=True,
            ),
            self._tool_def(
                name="bss_get_bootscript",
                description="Fetch a BSS bootscript by mac, name, or nid.",
                input_schema={
                    "type": "object",
                    "properties": {
                        "mac": {"type": "string"},
                        "name": {"type": "string"},
                        "nid": {"anyOf": [{"type": "string"}, {"type": "integer"}]},
                        "retry": {"type": "integer", "minimum": 0},
                    },
                    "anyOf": [
                        {"required": ["mac"]},
                        {"required": ["name"]},
                        {"required": ["nid"]},
                    ],
                },
                read_only=True,
            ),
            self._tool_def(
                name="bss_list_hosts",
                description="List BSS hosts.",
                input_schema={"type": "object", "properties": {}},
                read_only=True,
            ),
            self._tool_def(
                name="bss_put_bootparameters",
                description="Replace/update BSS boot parameters (read-write mode only).",
                input_schema={
                    "type": "object",
                    "properties": {"payload": {"type": "object"}},
                    "required": ["payload"],
                },
                read_only=False,
            ),
            self._tool_def(
                name="bss_post_bootparameters",
                description="Create BSS boot parameters (read-write mode only).",
                input_schema={
                    "type": "object",
                    "properties": {"payload": {"type": "object"}},
                    "required": ["payload"],
                },
                read_only=False,
            ),
            self._tool_def(
                name="bss_patch_bootparameters",
                description="Patch BSS boot parameters (read-write mode only).",
                input_schema={
                    "type": "object",
                    "properties": {"payload": {"type": "object"}},
                    "required": ["payload"],
                },
                read_only=False,
            ),
            self._tool_def(
                name="bss_delete_bootparameters",
                description="Delete BSS boot parameters (read-write mode only).",
                input_schema={
                    "type": "object",
                    "properties": {"payload": {"type": "object"}},
                    "required": ["payload"],
                },
                read_only=False,
            ),
            self._tool_def(
                name="bss_hosts_post",
                description="Create/update BSS hosts (read-write mode only).",
                input_schema={
                    "type": "object",
                    "properties": {"payload": {"type": "object"}},
                    "required": ["payload"],
                },
                read_only=False,
            ),
            self._tool_def(
                name="pcs_transition",
                description=(
                    "Run a PCS transition operation (read-write mode only). "
                    "Examples: on, off, force-off, soft-restart."
                ),
                input_schema={
                    "type": "object",
                    "properties": {
                        "operation": {"type": "string"},
                        "xnames": {
                            "type": "array",
                            "items": {"type": "string"},
                            "minItems": 1,
                        },
                    },
                    "required": ["operation", "xnames"],
                },
                read_only=False,
            ),
            self._tool_def(
                name="hsm_create_group",
                description="Create an HSM group (read-write mode only).",
                input_schema={
                    "type": "object",
                    "properties": {
                        "label": {"type": "string"},
                        "description": {"type": "string"},
                        "members": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                        "payload": {"type": "object"},
                        "endpoint": {"type": "string"},
                    },
                },
                read_only=False,
            ),
            self._tool_def(
                name="hsm_delete_group",
                description="Delete an HSM group by label (read-write mode only).",
                input_schema={
                    "type": "object",
                    "properties": {
                        "label": {"type": "string"},
                        "endpoint": {"type": "string"},
                    },
                    "required": ["label"],
                },
                read_only=False,
            ),
            self._tool_def(
                name="hsm_update_group_members",
                description=(
                    "Update HSM group members (read-write mode only). "
                    "Default endpoint is /hsm/v2/groups/{label}/members."
                ),
                input_schema={
                    "type": "object",
                    "properties": {
                        "label": {"type": "string"},
                        "members": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                        "action": {"type": "string", "default": "replace"},
                        "method": {"type": "string", "default": "POST"},
                        "payload": {"type": "object"},
                        "endpoint": {"type": "string"},
                    },
                    "required": ["label", "members"],
                },
                read_only=False,
            ),
        ]

    def call_tool(self, name: str, arguments: Optional[Dict[str, Any]]) -> Dict[str, Any]:
        args = arguments or {}
        handler = self._tools.get(name)
        if handler is None:
            raise ValueError(f"Unknown tool: {name}")
        if name in self._write_tools:
            self._require_write_enabled(name)
        response = handler(args)
        return {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(response, indent=2, sort_keys=True),
                }
            ]
        }

    def _build_tool_map(self) -> Dict[str, Callable[[Dict[str, Any]], Any]]:
        return {
            "openchami_health": self._tool_health,
            "hsm_list_components": self._tool_hsm_list_components,
            "hsm_get_component": self._tool_hsm_get_component,
            "hsm_list_groups": self._tool_hsm_list_groups,
            "hsm_get_group": self._tool_hsm_get_group,
            "pcs_power_status": self._tool_pcs_power_status,
            "bss_service_status": self._tool_bss_service_status,
            "bss_get_bootparameters": self._tool_bss_get_bootparameters,
            "bss_get_bootscript": self._tool_bss_get_bootscript,
            "bss_list_hosts": self._tool_bss_list_hosts,
            "bss_put_bootparameters": self._tool_bss_put_bootparameters,
            "bss_post_bootparameters": self._tool_bss_post_bootparameters,
            "bss_patch_bootparameters": self._tool_bss_patch_bootparameters,
            "bss_delete_bootparameters": self._tool_bss_delete_bootparameters,
            "bss_hosts_post": self._tool_bss_hosts_post,
            "pcs_transition": self._tool_pcs_transition,
            "hsm_create_group": self._tool_hsm_create_group,
            "hsm_delete_group": self._tool_hsm_delete_group,
            "hsm_update_group_members": self._tool_hsm_update_group_members,
        }

    def _tool_health(self, args: Dict[str, Any]) -> Dict[str, Any]:
        timeout = int(args.get("timeout", 5))
        checks = {
            "smd_ready": "/hsm/v2/service/ready",
            "bss_ready": "/boot/v1/service/status",
            "http_boot_script": "/boot.ipxe",
        }
        out: Dict[str, Any] = {}
        for key, path in checks.items():
            try:
                out[key] = {"ok": True, "response": self.api_client.request("GET", path, timeout=timeout)}
            except OpenChamiApiError as exc:
                out[key] = {"ok": False, "error": str(exc)}
        return out

    def _tool_hsm_list_components(self, _args: Dict[str, Any]) -> Any:
        return self.api_client.request("GET", "/hsm/v2/State/Components")

    def _tool_hsm_get_component(self, args: Dict[str, Any]) -> Any:
        xname = self._required_str(args, "xname")
        return self.api_client.request("GET", f"/hsm/v2/State/Components/{quote(xname, safe='')}")

    def _tool_hsm_list_groups(self, _args: Dict[str, Any]) -> Any:
        return self.api_client.request("GET", "/hsm/v2/groups")

    def _tool_hsm_get_group(self, args: Dict[str, Any]) -> Any:
        label = self._required_str(args, "label")
        return self.api_client.request("GET", f"/hsm/v2/groups/{quote(label, safe='')}")

    def _tool_pcs_power_status(self, args: Dict[str, Any]) -> Any:
        xnames = self._required_string_list(args, "xnames")
        payload = {"xname": xnames}
        return self.api_client.request("POST", "/power-control/v1/power-status", payload=payload)

    def _tool_bss_service_status(self, _args: Dict[str, Any]) -> Any:
        return self.api_client.request("GET", "/boot/v1/service/status")

    def _tool_bss_get_bootparameters(self, _args: Dict[str, Any]) -> Any:
        return self.api_client.request("GET", "/boot/v1/bootparameters")

    def _tool_bss_get_bootscript(self, args: Dict[str, Any]) -> Any:
        query: Dict[str, str] = {}
        for key in ("mac", "name"):
            value = args.get(key)
            if value is None:
                continue
            if not isinstance(value, str) or not value.strip():
                raise ValueError(f"'{key}' must be a non-empty string")
            query[key] = value.strip()

        nid_value = args.get("nid")
        if nid_value is not None:
            if isinstance(nid_value, int):
                query["nid"] = str(nid_value)
            elif isinstance(nid_value, str) and nid_value.strip():
                query["nid"] = nid_value.strip()
            else:
                raise ValueError("'nid' must be an integer or non-empty string")

        retry_value = args.get("retry")
        if retry_value is not None:
            if isinstance(retry_value, int) and retry_value >= 0:
                query["retry"] = str(retry_value)
            else:
                raise ValueError("'retry' must be a non-negative integer")

        if not any(selector in query for selector in ("mac", "name", "nid")):
            raise ValueError("One of 'mac', 'name', or 'nid' is required")

        path = self._path_with_query("/boot/v1/bootscript", query)
        return self.api_client.request("GET", path)

    def _tool_bss_list_hosts(self, _args: Dict[str, Any]) -> Any:
        return self.api_client.request("GET", "/boot/v1/hosts")

    def _tool_bss_put_bootparameters(self, args: Dict[str, Any]) -> Any:
        payload = self._required_object(args, "payload")
        return self.api_client.request("PUT", "/boot/v1/bootparameters", payload=payload)

    def _tool_bss_post_bootparameters(self, args: Dict[str, Any]) -> Any:
        payload = self._required_object(args, "payload")
        return self.api_client.request("POST", "/boot/v1/bootparameters", payload=payload)

    def _tool_bss_patch_bootparameters(self, args: Dict[str, Any]) -> Any:
        payload = self._required_object(args, "payload")
        return self.api_client.request("PATCH", "/boot/v1/bootparameters", payload=payload)

    def _tool_bss_delete_bootparameters(self, args: Dict[str, Any]) -> Any:
        payload = self._required_object(args, "payload")
        return self.api_client.request("DELETE", "/boot/v1/bootparameters", payload=payload)

    def _tool_bss_hosts_post(self, args: Dict[str, Any]) -> Any:
        payload = self._required_object(args, "payload")
        return self.api_client.request("POST", "/boot/v1/hosts", payload=payload)

    def _tool_pcs_transition(self, args: Dict[str, Any]) -> Any:
        operation = self._required_str(args, "operation")
        xnames = self._required_string_list(args, "xnames")
        payload = {
            "operation": operation,
            "location": [{"xname": xname} for xname in xnames],
        }
        return self.api_client.request("POST", "/power-control/v1/transitions", payload=payload)

    def _tool_hsm_create_group(self, args: Dict[str, Any]) -> Any:
        endpoint = args.get("endpoint", "/hsm/v2/groups")
        payload = args.get("payload")
        if payload is None:
            label = self._required_str(args, "label")
            payload = {"label": label}
            description = args.get("description")
            if description:
                payload["description"] = description
            members = args.get("members")
            if members:
                payload["members"] = {"ids": members}
        return self.api_client.request("POST", endpoint, payload=payload)

    def _tool_hsm_delete_group(self, args: Dict[str, Any]) -> Any:
        label = self._required_str(args, "label")
        endpoint_template = args.get("endpoint", "/hsm/v2/groups/{label}")
        endpoint = endpoint_template.replace("{label}", quote(label, safe=""))
        return self.api_client.request("DELETE", endpoint)

    def _tool_hsm_update_group_members(self, args: Dict[str, Any]) -> Any:
        label = self._required_str(args, "label")
        endpoint_template = args.get("endpoint", "/hsm/v2/groups/{label}/members")
        endpoint = endpoint_template.replace("{label}", quote(label, safe=""))
        method = str(args.get("method", "POST")).upper()
        payload = args.get("payload")
        if payload is None:
            members = self._required_string_list(args, "members")
            action = args.get("action", "replace")
            payload = {"ids": members, "action": action}
        return self.api_client.request(method, endpoint, payload=payload)

    def _required_str(self, args: Dict[str, Any], key: str) -> str:
        value = args.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"'{key}' must be a non-empty string")
        return value

    def _required_string_list(self, args: Dict[str, Any], key: str) -> list[str]:
        value = args.get(key)
        if not isinstance(value, list) or not value:
            raise ValueError(f"'{key}' must be a non-empty list")
        out: list[str] = []
        for item in value:
            if not isinstance(item, str) or not item.strip():
                raise ValueError(f"'{key}' entries must be non-empty strings")
            out.append(item)
        return out

    def _required_object(self, args: Dict[str, Any], key: str) -> Dict[str, Any]:
        value = args.get(key)
        if not isinstance(value, dict) or not value:
            raise ValueError(f"'{key}' must be a non-empty object")
        return value

    def _path_with_query(self, path: str, query: Dict[str, str]) -> str:
        if not query:
            return path
        return f"{path}?{urlencode(query)}"

    def _require_write_enabled(self, tool_name: str) -> None:
        if self.mode != READ_WRITE_MODE:
            raise PermissionError(
                f"Tool '{tool_name}' is write-capable and requires --mode {READ_WRITE_MODE}."
            )
        if self.require_write_ack and not self._write_ack_set():
            raise PermissionError(
                "Write mode requires OPENCHAMI_MCP_ENABLE_WRITES=true to be set."
            )

    def _write_ack_set(self) -> bool:
        raw = os.environ.get("OPENCHAMI_MCP_ENABLE_WRITES", "")
        return raw.strip().lower() in TRUE_VALUES

    def _tool_def(
        self,
        name: str,
        description: str,
        input_schema: Dict[str, Any],
        read_only: bool,
    ) -> Dict[str, Any]:
        return {
            "name": name,
            "description": description,
            "inputSchema": input_schema,
            "annotations": {"readOnlyHint": read_only},
        }


def _read_non_empty_line(stream: Any) -> bytes:
    line = stream.readline()
    while line in (b"\r\n", b"\n"):
        line = stream.readline()
    return line


def _looks_like_json(line: bytes) -> bool:
    stripped = line.lstrip()
    return stripped.startswith(b"{") or stripped.startswith(b"[")


def _parse_jsonl_message(line: bytes) -> Dict[str, Any]:
    return json.loads(line.decode("utf-8", errors="replace").strip())


def _parse_content_length_message(stream: Any, first_line: bytes) -> Dict[str, Any]:
    headers: Dict[str, str] = {}
    line = first_line

    while line and line not in (b"\r\n", b"\n"):
        decoded = line.decode("utf-8", errors="replace").strip()
        if ":" not in decoded:
            raise ValueError(f"Invalid header line: {decoded}")
        key, value = decoded.split(":", 1)
        headers[key.strip().lower()] = value.strip()
        line = stream.readline()

    content_length_raw = headers.get("content-length")
    if content_length_raw is None:
        raise ValueError("Missing Content-Length header")
    content_length = int(content_length_raw)
    body = stream.read(content_length)
    if len(body) != content_length:
        raise EOFError("Unexpected EOF while reading JSON-RPC payload")
    return json.loads(body.decode("utf-8"))


def read_jsonrpc_message(
    stdin: Any,
    framing_state: Optional[Dict[str, str]] = None,
) -> Optional[Dict[str, Any]]:
    mode = None
    if framing_state is not None:
        mode = framing_state.get("mode")

    line = _read_non_empty_line(stdin.buffer)
    if not line:
        return None

    if mode is None:
        mode = FRAMING_JSONL if _looks_like_json(line) else FRAMING_CONTENT_LENGTH
        if framing_state is not None:
            framing_state["mode"] = mode

    if mode == FRAMING_JSONL:
        return _parse_jsonl_message(line)
    if mode == FRAMING_CONTENT_LENGTH:
        return _parse_content_length_message(stdin.buffer, line)

    raise ValueError(f"Unsupported framing mode: {mode}")


def write_jsonrpc_message(
    stdout: Any,
    payload: Dict[str, Any],
    framing_state: Optional[Dict[str, str]] = None,
) -> None:
    mode = FRAMING_JSONL
    if framing_state is not None and framing_state.get("mode"):
        mode = framing_state["mode"]

    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    if mode == FRAMING_CONTENT_LENGTH:
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        stdout.buffer.write(header)
        stdout.buffer.write(body)
    elif mode == FRAMING_JSONL:
        stdout.buffer.write(body + b"\n")
    else:
        raise ValueError(f"Unsupported framing mode: {mode}")

    stdout.buffer.flush()


def build_error_response(request_id: Any, code: int, message: str, data: Any = None) -> Dict[str, Any]:
    error: Dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def build_result_response(request_id: Any, result: Any) -> Dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def handle_request(
    server: OpenChamiMcpServer,
    request: Dict[str, Any],
) -> Optional[Dict[str, Any]]:
    request_id = request.get("id")
    method = request.get("method")
    params = request.get("params", {})

    if not method:
        if request_id is None:
            return None
        return build_error_response(request_id, -32600, "Invalid Request: missing method")

    try:
        if method == "initialize":
            result = {
                "protocolVersion": DEFAULT_PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "openchami-mcp", "version": "0.1.0"},
            }
            if request_id is not None:
                return build_result_response(request_id, result)
            return None

        if method == "notifications/initialized":
            return None

        if method == "ping":
            if request_id is not None:
                return build_result_response(request_id, {})
            return None

        if method == "tools/list":
            if request_id is None:
                return None
            return build_result_response(request_id, {"tools": server.list_tools()})

        if method == "tools/call":
            if request_id is None:
                return None
            if not isinstance(params, dict):
                return build_error_response(request_id, -32602, "Invalid params for tools/call")
            name = params.get("name")
            arguments = params.get("arguments", {})
            if not isinstance(name, str) or not name:
                return build_error_response(request_id, -32602, "Missing tool name")
            if not isinstance(arguments, dict):
                return build_error_response(request_id, -32602, "Tool arguments must be an object")
            result = server.call_tool(name, arguments)
            return build_result_response(request_id, result)

        if method == "shutdown":
            if request_id is not None:
                return build_result_response(request_id, {})
            return None

        if method == "exit":
            raise SystemExit(0)

        if request_id is None:
            return None
        return build_error_response(request_id, -32601, f"Method not found: {method}")
    except PermissionError as exc:
        return build_error_response(request_id, -32001, str(exc))
    except OpenChamiApiError as exc:
        return build_error_response(
            request_id,
            -32002,
            "OpenCHAMI API request failed",
            {
                "message": exc.message,
                "status_code": exc.status_code,
                "response_body": exc.response_body,
            },
        )
    except ValueError as exc:
        return build_error_response(request_id, -32602, str(exc))
    except SystemExit:
        raise
    except Exception as exc:  # pragma: no cover - defensive guard for runtime errors
        return build_error_response(request_id, -32603, f"Internal error: {exc}")


def serve_stdio(server: OpenChamiMcpServer) -> int:
    framing_state: Dict[str, str] = {}
    while True:
        try:
            message = read_jsonrpc_message(sys.stdin, framing_state)
            if message is None:
                return 0
            response = handle_request(server, message)
            if response is not None and response.get("id") is not None:
                write_jsonrpc_message(sys.stdout, response, framing_state)
        except SystemExit:
            return 0
        except EOFError:
            return 0
        except Exception as exc:
            # If a malformed request has no id, emit to stderr and continue.
            print(f"openchami-mcp: {exc}", file=sys.stderr)
    return 0


def parse_args(argv: Optional[Iterable[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Minimal MCP server for local OpenCHAMI control."
    )
    parser.add_argument(
        "--base-url",
        default=os.environ.get("OPENCHAMI_BASE_URL", "http://192.168.100.2:30080"),
        help="Reverse-proxy base URL for OpenCHAMI APIs (default: %(default)s)",
    )
    parser.add_argument(
        "--mode",
        choices=[READ_ONLY_MODE, READ_WRITE_MODE],
        default=os.environ.get("OPENCHAMI_MCP_MODE", READ_ONLY_MODE),
        help="Server mode (default: %(default)s)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=int(os.environ.get("OPENCHAMI_MCP_TIMEOUT", "10")),
        help="HTTP timeout in seconds for API calls (default: %(default)s)",
    )
    parser.add_argument(
        "--no-write-ack",
        action="store_true",
        help="Disable the OPENCHAMI_MCP_ENABLE_WRITES=true write-ack requirement.",
    )
    return parser.parse_args(argv)


def main(argv: Optional[Iterable[str]] = None) -> int:
    args = parse_args(argv)
    client = OpenChamiApiClient(base_url=args.base_url, timeout=args.timeout)
    server = OpenChamiMcpServer(
        api_client=client,
        mode=args.mode,
        require_write_ack=not args.no_write_ack,
    )
    return serve_stdio(server)


if __name__ == "__main__":
    raise SystemExit(main())
