#!/usr/bin/env python3
"""API-level tests for the Hetzner Robot reconciler."""

from __future__ import annotations

import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from automation.hetzner_robot.robot import (  # noqa: E402
    ApiError,
    AutomationConfig,
    ConfigError,
    ReconcileError,
    Reconciler,
    RobotClient,
    ServerSpec,
    StateStore,
)


class FakeRobot:
    def __init__(self) -> None:
        self.requests: list[dict[str, object]] = []
        self.linux: dict[str, object] = {
            "active": False,
            "dist": ["Ubuntu 24.04"],
            "lang": ["en"],
            "authorized_key": [],
        }
        self.server: dict[str, object] = {"server_number": 123, "cancelled": False}
        self.failures: dict[tuple[str, str], list[tuple[int, object]]] = {}
        self.reset_count = 0
        self.activate_count = 0

    def response_for(self, method: str, path: str, body: dict[str, list[str]]) -> tuple[int, object]:
        self.requests.append({"method": method, "path": path, "body": body})
        if method == "POST" and path == "/reset/123":
            self.reset_count += 1
        failures = self.failures.get((method, path), [])
        if failures:
            return failures.pop(0)

        if method == "GET" and path == "/server/123":
            return 200, {"server": self.server}
        if method == "GET" and path == "/boot/123/linux":
            return 200, {"linux": self.linux}
        if method == "POST" and path == "/boot/123/linux":
            self.activate_count += 1
            self.linux = {
                "active": True,
                "dist": body["dist"][0],
                "lang": body["lang"][0],
                "authorized_key": body.get("authorized_key[]", []),
            }
            return 201, {"linux": self.linux}
        if method == "POST" and path == "/reset/123":
            return 200, {"reset": {"server_number": 123, "type": body["type"][0]}}
        return 404, {"error": {"code": "NOT_FOUND", "message": "not found"}}


class RobotHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body = parse_qs(self.rfile.read(content_length).decode("utf-8"))
        fake: FakeRobot = self.server.fake  # type: ignore[attr-defined]
        status, payload = fake.response_for(method, self.path, body)
        request = fake.requests[-1]
        request["authorization"] = self.headers.get("Authorization")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode("utf-8"))

    def log_message(self, *_args: object) -> None:
        return


class RobotServer:
    def __init__(self, fake: FakeRobot) -> None:
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), RobotHandler)
        self.httpd.fake = fake  # type: ignore[attr-defined]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.httpd.server_port}"

    def __enter__(self) -> "RobotServer":
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.httpd.shutdown()
        self.thread.join()
        self.httpd.server_close()


def desired_spec(*, reinstall_on_drift: bool = False) -> ServerSpec:
    return ServerSpec(
        server_number=123,
        distribution="Ubuntu 24.04",
        language="en",
        authorized_keys=("SHA256:test-key",),
        reinstall_on_drift=reinstall_on_drift,
    )


class RobotApiTests(unittest.TestCase):
    def client(self, server: RobotServer, *, max_attempts: int = 1) -> RobotClient:
        return RobotClient(
            server.url,
            "robot-user",
            "robot-password",
            max_attempts=max_attempts,
            sleeper=lambda _seconds: None,
            allow_insecure_http=True,
        )

    def reconciler(self, server: RobotServer, directory: str, *, max_attempts: int = 1) -> Reconciler:
        return Reconciler(
            self.client(server, max_attempts=max_attempts),
            StateStore(Path(directory) / "state.json"),
        )

    def test_matching_linux_install_is_a_noop_and_sends_basic_auth(self) -> None:
        fake = FakeRobot()
        fake.linux = {
            "active": True,
            "dist": "Ubuntu 24.04",
            "lang": "en",
            "authorized_key": ["SHA256:test-key"],
        }
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            result = self.reconciler(server, directory).reconcile(desired_spec())

        self.assertEqual(result.action, "noop")
        self.assertFalse(result.changed)
        self.assertEqual(fake.activate_count, 0)
        self.assertEqual(fake.reset_count, 0)
        self.assertEqual(
            fake.requests[0]["authorization"],
            "Basic " + base64.b64encode(b"robot-user:robot-password").decode(),
        )

    def test_inactive_server_is_activated_and_reset_once(self) -> None:
        fake = FakeRobot()
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            reconciler = self.reconciler(server, directory)
            result = reconciler.reconcile(desired_spec())
            second = reconciler.reconcile(desired_spec())

        self.assertEqual(result.action, "activate-linux-and-reset")
        self.assertTrue(result.changed)
        self.assertEqual(second.action, "noop")
        self.assertEqual(fake.activate_count, 1)
        self.assertEqual(fake.reset_count, 1)
        post_requests = [request for request in fake.requests if request["method"] == "POST"]
        self.assertEqual(post_requests[0]["body"]["authorized_key[]"], ["SHA256:test-key"])

    def test_failed_reset_is_resumed_without_reactivating_linux(self) -> None:
        fake = FakeRobot()
        fake.failures[("POST", "/reset/123")] = [
            (503, {"error": {"code": "RESET_FAILED", "message": "try again"}})
        ]
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            reconciler = self.reconciler(server, directory)
            with self.assertRaises(ApiError):
                reconciler.reconcile(desired_spec())
            state = json.loads((Path(directory) / "state.json").read_text())
            self.assertEqual(state["servers"]["123"]["action"], "reset")
            result = reconciler.reconcile(desired_spec())

        self.assertEqual(result.action, "reset-recovery")
        self.assertEqual(fake.activate_count, 1)
        self.assertEqual(fake.reset_count, 2)

    def test_transient_api_failure_is_retried_but_auth_failure_is_not(self) -> None:
        fake = FakeRobot()
        fake.failures[("GET", "/server/123")] = [
            (503, {"error": {"code": "MAINTENANCE", "message": "try again"}})
        ]
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            result = self.reconciler(server, directory, max_attempts=2).reconcile(desired_spec())
        self.assertEqual(result.action, "activate-linux-and-reset")
        self.assertEqual(len([r for r in fake.requests if r["path"] == "/server/123"]), 2)

        fake = FakeRobot()
        fake.failures[("GET", "/server/123")] = [
            (401, {"error": {"code": "AUTHENTICATION_FAILED", "message": "bad password"}})
        ]
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            with self.assertRaises(ApiError) as raised:
                self.reconciler(server, directory, max_attempts=3).reconcile(desired_spec())
        self.assertFalse(raised.exception.retryable)
        self.assertNotIn("robot-password", str(raised.exception))
        self.assertEqual(len([r for r in fake.requests if r["path"] == "/server/123"]), 1)

    def test_active_drift_requires_explicit_reinstall_permission(self) -> None:
        fake = FakeRobot()
        fake.linux = {
            "active": True,
            "dist": "Debian 12",
            "lang": "en",
            "authorized_key": [],
        }
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            with self.assertRaises(ReconcileError):
                self.reconciler(server, directory).reconcile(desired_spec())
        self.assertEqual(fake.activate_count, 0)

    def test_https_is_required_by_default_and_config_is_validated(self) -> None:
        with self.assertRaises(ConfigError):
            RobotClient("http://localhost", "user", "password")
        with self.assertRaises(ConfigError):
            AutomationConfig.from_mapping(
                {
                    "servers": [
                        {"server_number": 123, "distribution": "Ubuntu"},
                        {"server_number": 123, "distribution": "Ubuntu"},
                    ]
                }
            )


if __name__ == "__main__":
    unittest.main()
