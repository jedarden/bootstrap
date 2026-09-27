#!/usr/bin/env python3
"""Idempotent Linux provisioning through the Hetzner Robot Webservice.

The Robot API uses HTTP Basic authentication and form-encoded POST bodies.  This
module deliberately uses only Python's standard library so it can be mounted
into a small Kubernetes workload without a package installation step.

The reconciler owns activation of the Robot Linux installer and, after a
successful activation, a software reset.  It does not attempt to SSH to the
machine; the existing bootstrap script remains responsible for host
configuration after the operating system is available.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from dataclasses import dataclass
from http.client import HTTPException
from typing import Any, Callable, Mapping, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


DEFAULT_BASE_URL = "https://robot-ws.your-server.de"
TRANSIENT_HTTP_STATUS = frozenset({408, 425, 429})


class ConfigError(ValueError):
    """The declarative configuration is invalid."""


class ReconcileError(RuntimeError):
    """A server could not be reconciled safely."""


class ApiError(RuntimeError):
    """A Robot API request failed without exposing response secrets."""

    def __init__(
        self,
        method: str,
        path: str,
        status: int | None,
        code: str,
        message: str,
        *,
        retryable: bool = False,
    ) -> None:
        self.method = method
        self.path = path
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        status_text = str(status) if status is not None else "transport"
        super().__init__(f"{method} {path} failed ({status_text} {code}): {message}")


@dataclass(frozen=True)
class ServerSpec:
    """One desired Linux installation in Robot."""

    server_number: int
    distribution: str
    language: str = "en"
    authorized_keys: tuple[str, ...] = ()
    reset_type: str = "sw"
    reinstall_on_drift: bool = False

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any], *, reinstall_on_drift: bool) -> "ServerSpec":
        if not isinstance(raw, Mapping):
            raise ConfigError("each servers entry must be an object")

        number = raw.get("server_number")
        if isinstance(number, bool) or not isinstance(number, int) or number <= 0:
            raise ConfigError("server_number must be a positive integer")

        distribution = raw.get("distribution")
        if not isinstance(distribution, str) or not distribution.strip():
            raise ConfigError(f"server {number}: distribution must be a non-empty string")

        language = raw.get("language", "en")
        if not isinstance(language, str) or not language.strip():
            raise ConfigError(f"server {number}: language must be a non-empty string")

        keys = raw.get("authorized_keys", ())
        if not isinstance(keys, (list, tuple)) or any(
            not isinstance(key, str) or not key.strip() for key in keys
        ):
            raise ConfigError(f"server {number}: authorized_keys must contain non-empty strings")

        reset_type = raw.get("reset_type", "sw")
        if reset_type not in {"sw", "hw", "man"}:
            raise ConfigError(f"server {number}: reset_type must be sw, hw, or man")

        per_server_reinstall = raw.get("reinstall_on_drift", reinstall_on_drift)
        if not isinstance(per_server_reinstall, bool):
            raise ConfigError(f"server {number}: reinstall_on_drift must be boolean")

        return cls(
            server_number=number,
            distribution=distribution,
            language=language,
            authorized_keys=tuple(keys),
            reset_type=reset_type,
            reinstall_on_drift=per_server_reinstall,
        )

    @property
    def fingerprint(self) -> str:
        payload = {
            "server_number": self.server_number,
            "distribution": self.distribution,
            "language": self.language,
            "authorized_keys": list(self.authorized_keys),
            "reset_type": self.reset_type,
        }
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(encoded).hexdigest()


@dataclass(frozen=True)
class AutomationConfig:
    servers: tuple[ServerSpec, ...]
    reset_after_change: bool = True

    @classmethod
    def from_mapping(cls, raw: Mapping[str, Any]) -> "AutomationConfig":
        if not isinstance(raw, Mapping):
            raise ConfigError("configuration root must be an object")
        raw_servers = raw.get("servers")
        if not isinstance(raw_servers, list):
            raise ConfigError("servers must be a list")

        reinstall_on_drift = raw.get("reinstall_on_drift", False)
        if not isinstance(reinstall_on_drift, bool):
            raise ConfigError("reinstall_on_drift must be boolean")

        reset_after_change = raw.get("reset_after_change", True)
        if not isinstance(reset_after_change, bool):
            raise ConfigError("reset_after_change must be boolean")

        servers = tuple(
            ServerSpec.from_mapping(item, reinstall_on_drift=reinstall_on_drift)
            for item in raw_servers
        )
        numbers = [server.server_number for server in servers]
        if len(numbers) != len(set(numbers)):
            raise ConfigError("servers must not contain duplicate server_number values")
        return cls(servers=servers, reset_after_change=reset_after_change)


def load_config(path: str | os.PathLike[str]) -> AutomationConfig:
    """Load and validate a JSON configuration file."""

    try:
        with open(path, "r", encoding="utf-8") as config_file:
            raw = json.load(config_file)
    except OSError as exc:
        raise ConfigError(f"could not read configuration: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"configuration is not valid JSON: {exc}") from exc
    return AutomationConfig.from_mapping(raw)


class StateStore:
    """Small atomic JSON store for activation operations awaiting a reset.

    The state file is intentionally optional for library users.  The Kubernetes
    deployment supplies a PVC-backed path so a pod restart can safely resume a
    reset after Robot accepted the installer activation but the reset request
    failed.
    """

    def __init__(self, path: str | os.PathLike[str] | None) -> None:
        self.path = Path(path) if path else None

    def _read(self) -> dict[str, Any]:
        if self.path is None or not self.path.exists():
            return {"servers": {}}
        try:
            with self.path.open("r", encoding="utf-8") as state_file:
                value = json.load(state_file)
        except (OSError, json.JSONDecodeError) as exc:
            raise ReconcileError(f"could not read state file: {exc}") from exc
        if not isinstance(value, dict) or not isinstance(value.get("servers", {}), dict):
            raise ReconcileError("state file has an invalid shape")
        return value

    def _write(self, value: Mapping[str, Any]) -> None:
        if self.path is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.", dir=self.path.parent
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as state_file:
                json.dump(value, state_file, sort_keys=True, indent=2)
                state_file.write("\n")
                state_file.flush()
                os.fsync(state_file.fileno())
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, self.path)
        except OSError as exc:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
            raise ReconcileError(f"could not write state file: {exc}") from exc

    def pending(self, server_number: int) -> Mapping[str, Any] | None:
        value = self._read()["servers"].get(str(server_number))
        return value if isinstance(value, Mapping) else None

    def mark_pending(self, spec: ServerSpec) -> None:
        value = self._read()
        value["servers"][str(spec.server_number)] = {
            "fingerprint": spec.fingerprint,
            "action": "reset",
        }
        self._write(value)

    def clear(self, server_number: int) -> None:
        value = self._read()
        value["servers"].pop(str(server_number), None)
        self._write(value)


class RobotClient:
    """Minimal Robot Webservice client with bounded transient retries."""

    def __init__(
        self,
        base_url: str,
        username: str,
        password: str,
        *,
        timeout: float = 30.0,
        max_attempts: int = 4,
        sleeper: Callable[[float], None] = time.sleep,
        allow_insecure_http: bool = False,
    ) -> None:
        if not username or not password:
            raise ConfigError("Robot username and password are required")
        if max_attempts < 1:
            raise ConfigError("max_attempts must be positive")
        self.base_url = base_url.rstrip("/")
        if not self.base_url.startswith("https://") and not allow_insecure_http:
            raise ConfigError("Robot API URL must use https")
        self.username = username
        self.password = password
        self.timeout = timeout
        self.max_attempts = max_attempts
        self.sleeper = sleeper
        credentials = f"{username}:{password}".encode("utf-8")
        self._authorization = "Basic " + base64.b64encode(credentials).decode("ascii")

    def _request(
        self, method: str, path: str, form: Mapping[str, Any] | None = None
    ) -> Any:
        body = None
        if form is not None:
            body = urlencode(form, doseq=True).encode("utf-8")
        last_error: ApiError | None = None

        for attempt in range(1, self.max_attempts + 1):
            request = Request(
                f"{self.base_url}{path}",
                data=body,
                method=method,
                headers={
                    "Accept": "application/json",
                    "Authorization": self._authorization,
                    "Content-Type": "application/x-www-form-urlencoded",
                    "User-Agent": "bootstrap-hetzner-robot/1",
                },
            )
            try:
                with urlopen(request, timeout=self.timeout) as response:
                    raw = response.read()
                if not raw:
                    return {}
                try:
                    return json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise ApiError(
                        method,
                        path,
                        response.status,
                        "INVALID_RESPONSE",
                        "Robot returned invalid JSON",
                    ) from exc
            except HTTPError as exc:
                error_code, error_message = _error_details(exc)
                retryable = exc.code in TRANSIENT_HTTP_STATUS or exc.code >= 500
                last_error = ApiError(
                    method,
                    path,
                    exc.code,
                    error_code,
                    error_message,
                    retryable=retryable,
                )
                if not retryable or attempt == self.max_attempts:
                    raise last_error from exc
                self.sleeper(_retry_delay(attempt, exc.headers.get("Retry-After")))
            except (TimeoutError, URLError, HTTPException, OSError) as exc:
                last_error = ApiError(
                    method,
                    path,
                    None,
                    "TRANSPORT_ERROR",
                    "request could not be completed",
                    retryable=True,
                )
                if attempt == self.max_attempts:
                    raise last_error from exc
                self.sleeper(_retry_delay(attempt, None))

        assert last_error is not None
        raise last_error

    def get_server(self, server_number: int) -> Mapping[str, Any]:
        return _named_object(self._request("GET", f"/server/{server_number}"), "server")

    def get_linux(self, server_number: int) -> Mapping[str, Any]:
        return _named_object(self._request("GET", f"/boot/{server_number}/linux"), "linux")

    def activate_linux(self, spec: ServerSpec) -> Mapping[str, Any]:
        form: dict[str, Any] = {"dist": spec.distribution, "lang": spec.language}
        if spec.authorized_keys:
            form["authorized_key[]"] = list(spec.authorized_keys)
        return _named_object(
            self._request("POST", f"/boot/{spec.server_number}/linux", form), "linux"
        )

    def reset(self, spec: ServerSpec) -> Mapping[str, Any]:
        return _named_object(
            self._request(
                "POST", f"/reset/{spec.server_number}", {"type": spec.reset_type}
            ),
            "reset",
        )


@dataclass(frozen=True)
class ReconcileResult:
    server_number: int
    changed: bool
    action: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "server_number": self.server_number,
            "changed": self.changed,
            "action": self.action,
        }


class Reconciler:
    def __init__(
        self, client: RobotClient, state_store: StateStore, *, reset_after_change: bool = True
    ) -> None:
        self.client = client
        self.state_store = state_store
        self.reset_after_change = reset_after_change

    def reconcile(self, spec: ServerSpec, *, dry_run: bool = False) -> ReconcileResult:
        server = self.client.get_server(spec.server_number)
        if server.get("cancelled") is True:
            raise ReconcileError(f"server {spec.server_number} is cancelled")

        linux = self.client.get_linux(spec.server_number)
        matches = _linux_matches(linux, spec)
        pending = self.state_store.pending(spec.server_number)

        if matches and pending and pending.get("fingerprint") == spec.fingerprint:
            if dry_run:
                return ReconcileResult(spec.server_number, True, "reset-recovery")
            self.client.reset(spec)
            self.state_store.clear(spec.server_number)
            return ReconcileResult(spec.server_number, True, "reset-recovery")

        if matches:
            return ReconcileResult(spec.server_number, False, "noop")

        if linux.get("active") is True and not spec.reinstall_on_drift:
            raise ReconcileError(
                f"server {spec.server_number} has an active Linux configuration that differs "
                "from the desired state; set reinstall_on_drift=true to replace it"
            )

        if dry_run:
            return ReconcileResult(spec.server_number, True, "activate-linux-and-reset")

        self.client.activate_linux(spec)
        if not self.reset_after_change:
            return ReconcileResult(spec.server_number, True, "activate-linux")

        # Record the accepted activation before the reset so a pod restart can
        # retry the reset without activating the installer a second time.
        self.state_store.mark_pending(spec)
        self.client.reset(spec)
        self.state_store.clear(spec.server_number)
        return ReconcileResult(spec.server_number, True, "activate-linux-and-reset")


def _named_object(payload: Any, name: str) -> Mapping[str, Any]:
    if not isinstance(payload, Mapping) or not isinstance(payload.get(name), Mapping):
        raise ApiError("response", name, None, "INVALID_RESPONSE", f"missing {name} object")
    return payload[name]


def _linux_matches(linux: Mapping[str, Any], spec: ServerSpec) -> bool:
    if linux.get("active") is not True:
        return False
    if linux.get("dist") != spec.distribution or linux.get("lang") != spec.language:
        return False
    if spec.authorized_keys:
        actual_keys = sorted(str(key) for key in linux.get("authorized_key", ()))
        if actual_keys != sorted(spec.authorized_keys):
            return False
    return True


def _error_details(error: HTTPError) -> tuple[str, str]:
    try:
        payload = json.loads(error.read(64 * 1024).decode("utf-8"))
        details = payload.get("error", {}) if isinstance(payload, Mapping) else {}
        if isinstance(details, Mapping):
            code = details.get("code")
            message = details.get("message")
            if isinstance(code, str) and isinstance(message, str):
                return code, message
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        pass
    return "HTTP_ERROR", "Robot API request failed"


def _retry_delay(attempt: int, retry_after: str | None) -> float:
    if retry_after:
        try:
            return min(max(float(retry_after), 0.0), 30.0)
        except ValueError:
            pass
    return min(2 ** (attempt - 1), 30)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    reconcile = subparsers.add_parser("reconcile", help="reconcile declared Linux installations")
    reconcile.add_argument("--config", required=True, help="path to JSON desired-state file")
    reconcile.add_argument(
        "--state-file",
        default="/var/lib/hetzner-robot/state.json",
        help="durable pending-operation state path",
    )
    reconcile.add_argument("--dry-run", action="store_true")
    reconcile.add_argument("--base-url", default=os.environ.get("HETZNER_ROBOT_URL", DEFAULT_BASE_URL))
    reconcile.add_argument("--timeout", type=float, default=30.0)
    reconcile.add_argument("--max-attempts", type=int, default=4)
    reconcile.add_argument(
        "--interval",
        type=float,
        default=0,
        help="repeat reconciliation after this many seconds (Deployment mode)",
    )
    reconcile.add_argument(
        "--allow-insecure-http",
        action="store_true",
        help="allow HTTP endpoints for local tests only",
    )
    return parser


def _run_reconcile(args: argparse.Namespace) -> int:
    try:
        config = load_config(args.config)
        username = os.environ.get("HETZNER_ROBOT_USERNAME", "")
        password = os.environ.get("HETZNER_ROBOT_PASSWORD", "")
        client = RobotClient(
            args.base_url,
            username,
            password,
            timeout=args.timeout,
            max_attempts=args.max_attempts,
            allow_insecure_http=args.allow_insecure_http,
        )
        reconciler = Reconciler(
            client,
            StateStore(args.state_file),
            reset_after_change=config.reset_after_change,
        )
        failures: list[str] = []
        for spec in config.servers:
            try:
                result = reconciler.reconcile(spec, dry_run=args.dry_run)
                print(json.dumps(result.as_dict(), sort_keys=True))
            except (ApiError, ReconcileError) as exc:
                # Do not print response bodies: Robot responses can contain
                # generated root or rescue passwords.
                failures.append(f"server {spec.server_number}: {exc}")
        if failures:
            for failure in failures:
                print(failure, file=sys.stderr)
            return 1
        return 0
    except (ConfigError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.command != "reconcile":
        return 2
    if args.interval < 0:
        print("--interval must not be negative", file=sys.stderr)
        return 2
    while True:
        result = _run_reconcile(args)
        if args.interval == 0 or result == 2:
            return result
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
