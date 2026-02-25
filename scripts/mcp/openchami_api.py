#!/usr/bin/env python3
"""HTTP client helpers for talking to local OpenCHAMI APIs via reverse proxy."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Dict, Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


@dataclass
class OpenChamiApiError(Exception):
    """Represents an HTTP/API failure when talking to OpenCHAMI."""

    message: str
    status_code: Optional[int] = None
    response_body: Optional[str] = None

    def __str__(self) -> str:
        parts = [self.message]
        if self.status_code is not None:
            parts.append(f"(status={self.status_code})")
        if self.response_body:
            parts.append(f"body={self.response_body}")
        return " ".join(parts)


class OpenChamiApiClient:
    """Small JSON-first HTTP client for OpenCHAMI routes."""

    def __init__(self, base_url: str, timeout: int = 10):
        if not base_url:
            raise ValueError("base_url must be non-empty")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def build_url(self, path: str) -> str:
        normalized = path if path.startswith("/") else f"/{path}"
        return f"{self.base_url}{normalized}"

    def request(
        self,
        method: str,
        path: str,
        payload: Optional[Dict[str, Any]] = None,
        timeout: Optional[int] = None,
    ) -> Any:
        verb = method.upper()
        url = self.build_url(path)
        req_headers = {
            "Accept": "application/json",
        }
        req_body = None
        if payload is not None:
            req_headers["Content-Type"] = "application/json"
            req_body = json.dumps(payload).encode("utf-8")

        request = Request(url=url, data=req_body, method=verb, headers=req_headers)
        try:
            with urlopen(request, timeout=timeout or self.timeout) as response:
                raw = response.read().decode("utf-8", errors="replace")
                if not raw:
                    return {"status": response.status}
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    return {"status": response.status, "text": raw}
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise OpenChamiApiError(
                message=f"HTTP request failed for {verb} {url}",
                status_code=exc.code,
                response_body=body,
            ) from exc
        except URLError as exc:
            raise OpenChamiApiError(
                message=f"Failed to connect to OpenCHAMI endpoint {url}: {exc.reason}",
            ) from exc
