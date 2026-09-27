#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -m unittest discover -s "$ROOT/tests" -p 'hetzner_robot_test.py' -v
