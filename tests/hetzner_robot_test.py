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
        self.failures: dict[
            tuple[str, str], list[tuple[int, object] | tuple[int, object, dict[str, str]]]
        ] = {}
        self.reset_count = 0
        self.activate_count = 0

    def response_for(
        self, method: str, path: str, body: dict[str, list[str]]
    ) -> tuple[int, object, dict[str, str]]:
        self.requests.append({"method": method, "path": path, "body": body})
        if method == "POST" and path == "/reset/123":
            self.reset_count += 1
        failures = self.failures.get((method, path), [])
        if failures:
            failure = failures.pop(0)
            if len(failure) == 2:
                return failure[0], failure[1], {}
            return failure

        if method == "GET" and path == "/server/123":
            return 200, {"server": self.server}, {}
        if method == "GET" and path == "/boot/123/linux":
            return 200, {"linux": self.linux}, {}
        if method == "POST" and path == "/boot/123/linux":
            self.activate_count += 1
            self.linux = {
                "active": True,
                "dist": body["dist"][0],
                "lang": body["lang"][0],
                "authorized_key": body.get("authorized_key[]", []),
            }
            return 201, {"linux": self.linux}, {}
        if method == "POST" and path == "/reset/123":
            return 200, {"reset": {"server_number": 123, "type": body["type"][0]}}, {}
        return 404, {"error": {"code": "NOT_FOUND", "message": "not found"}}, {}


class RobotHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        content_length = int(self.headers.get("Content-Length", "0"))
        body = parse_qs(self.rfile.read(content_length).decode("utf-8"))
        fake: FakeRobot = self.server.fake  # type: ignore[attr-defined]
        status, payload, response_headers = fake.response_for(method, self.path, body)
        request = fake.requests[-1]
        request["authorization"] = self.headers.get("Authorization")
        request["headers"] = {
            "accept": self.headers.get("Accept"),
            "content-type": self.headers.get("Content-Type"),
            "user-agent": self.headers.get("User-Agent"),
        }
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for name, value in response_headers.items():
            self.send_header(name, value)
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


def desired_spec(*, reinstall_on_drift: bool = False, reset_type: str = "sw") -> ServerSpec:
    return ServerSpec(
        server_number=123,
        distribution="Ubuntu 24.04",
        language="en",
        authorized_keys=("SHA256:test-key",),
        reset_type=reset_type,
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
        self.assertEqual(
            fake.requests[0]["headers"],
            {
                "accept": "application/json",
                "content-type": "application/x-www-form-urlencoded",
                "user-agent": "bootstrap-hetzner-robot/1",
            },
        )

    def test_inactive_server_constructs_expected_requests_and_is_idempotent(self) -> None:
        fake = FakeRobot()
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            reconciler = self.reconciler(server, directory)
            result = reconciler.reconcile(desired_spec())
            second = reconciler.reconcile(desired_spec())
            state_after_reconcile = json.loads((Path(directory) / "state.json").read_text())

        self.assertEqual(result.action, "activate-linux-and-reset")
        self.assertTrue(result.changed)
        self.assertEqual(second.action, "noop")
        self.assertEqual(fake.activate_count, 1)
        self.assertEqual(fake.reset_count, 1)
        self.assertEqual(
            [
                (request["method"], request["path"], request["body"])
                for request in fake.requests
            ],
            [
                ("GET", "/server/123", {}),
                ("GET", "/boot/123/linux", {}),
                (
                    "POST",
                    "/boot/123/linux",
                    {
                        "dist": ["Ubuntu 24.04"],
                        "lang": ["en"],
                        "authorized_key[]": ["SHA256:test-key"],
                    },
                ),
                ("POST", "/reset/123", {"type": ["sw"]}),
                ("GET", "/server/123", {}),
                ("GET", "/boot/123/linux", {}),
            ],
        )
        self.assertEqual(state_after_reconcile, {"servers": {}})

    def test_reset_type_is_sent_to_the_reset_endpoint(self) -> None:
        fake = FakeRobot()
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            result = self.reconciler(server, directory).reconcile(
                desired_spec(reset_type="hw")
            )

        self.assertEqual(result.action, "activate-linux-and-reset")
        reset_requests = [request for request in fake.requests if request["path"] == "/reset/123"]
        self.assertEqual(reset_requests[0]["body"], {"type": ["hw"]})

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
            state_after_recovery = json.loads((Path(directory) / "state.json").read_text())

        self.assertEqual(result.action, "reset-recovery")
        self.assertEqual(fake.activate_count, 1)
        self.assertEqual(fake.reset_count, 2)
        self.assertEqual(state_after_recovery, {"servers": {}})

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

    def test_rate_limit_retries_honor_retry_after_and_stop_at_bound(self) -> None:
        fake = FakeRobot()
        fake.failures[("GET", "/server/123")] = [
            (429, {"error": {"code": "RATE_LIMIT", "message": "slow down"}}, {"Retry-After": "1.5"}),
            (429, {"error": {"code": "RATE_LIMIT", "message": "slow down"}}, {"Retry-After": "1.5"}),
            (429, {"error": {"code": "RATE_LIMIT", "message": "slow down"}}, {"Retry-After": "1.5"}),
        ]
        delays: list[float] = []
        with RobotServer(fake) as server:
            client = RobotClient(
                server.url,
                "robot-user",
                "robot-password",
                max_attempts=3,
                sleeper=delays.append,
                allow_insecure_http=True,
            )
            with self.assertRaises(ApiError) as raised:
                client.get_server(123)

        self.assertEqual(raised.exception.status, 429)
        self.assertEqual(raised.exception.code, "RATE_LIMIT")
        self.assertEqual(raised.exception.message, "slow down")
        self.assertTrue(raised.exception.retryable)
        self.assertEqual(delays, [1.5, 1.5])
        self.assertEqual(len(fake.requests), 3)

    def test_api_error_does_not_expose_response_body(self) -> None:
        fake = FakeRobot()
        fake.failures[("GET", "/server/123")] = [
            (
                400,
                {
                    "error": {
                        "code": "INVALID_SERVER",
                        "message": "invalid server",
                        "root_password": "generated-password",
                    }
                },
            )
        ]
        with RobotServer(fake) as server:
            client = self.client(server)
            with self.assertRaises(ApiError) as raised:
                client.get_server(123)

        self.assertEqual(raised.exception.status, 400)
        self.assertEqual(raised.exception.code, "INVALID_SERVER")
        self.assertFalse(raised.exception.retryable)
        self.assertNotIn("generated-password", str(raised.exception))

    def test_cancelled_server_is_rejected_without_provisioning_or_reset(self) -> None:
        fake = FakeRobot()
        fake.server["cancelled"] = True
        with tempfile.TemporaryDirectory() as directory, RobotServer(fake) as server:
            with self.assertRaises(ReconcileError):
                self.reconciler(server, directory).reconcile(desired_spec())

        self.assertEqual(fake.activate_count, 0)
        self.assertEqual(fake.reset_count, 0)
        self.assertEqual(
            [(request["method"], request["path"]) for request in fake.requests],
            [("GET", "/server/123")],
        )

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
