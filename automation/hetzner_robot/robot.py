#!/usr/bin/env python3
"""Import the Kubernetes-mounted Robot reconciler for local use and tests."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys


_SOURCE = Path(__file__).resolve().parents[2] / "k8s" / "hetzner-robot" / "robot.py"
_SPEC = importlib.util.spec_from_file_location("bootstrap_hetzner_robot", _SOURCE)
if _SPEC is None or _SPEC.loader is None:
    raise ImportError(f"could not load Robot reconciler from {_SOURCE}")
_MODULE = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = _MODULE
_SPEC.loader.exec_module(_MODULE)

for _name in (
    "ApiError",
    "AutomationConfig",
    "ConfigError",
    "ReconcileError",
    "Reconciler",
    "RobotClient",
    "ServerSpec",
    "StateStore",
    "load_config",
    "main",
):
    globals()[_name] = getattr(_MODULE, _name)


if __name__ == "__main__":
    raise SystemExit(main())
