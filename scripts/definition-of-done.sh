#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

case "${1:-}" in
    --fast)
        bash -n "$ROOT/hosts/ex44/bootstrap.sh"
        bash -n "$ROOT/hosts/ex44/start.sh"
        bash -n "$ROOT/tests/integration/host-fixture.sh"
        bash -n "$ROOT/tests/integration/bootstrap-test.sh"
        bash -n "$ROOT/tests/start-sh-self-update-test.sh"
        bash -n "$ROOT/scripts/start-sh-release.sh"
        "$ROOT/tests/start-sh-self-update-test.sh"
        "$ROOT/hosts/ex44/sync-start-sh.sh" --check
        "$ROOT/scripts/start-sh-release.sh" --check
        "$ROOT/ansible/validate.sh"
        ;;
    '')
        "$ROOT/scripts/definition-of-done.sh" --fast
        "$ROOT/tests/integration/bootstrap-test.sh"
        ;;
    *)
        echo "usage: scripts/definition-of-done.sh [--fast]" >&2
        exit 2
        ;;
esac
