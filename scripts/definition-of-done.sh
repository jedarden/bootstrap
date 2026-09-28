#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

case "${1:-}" in
    --fast)
        "$ROOT/scripts/check-hooks-path.sh" "$ROOT"
        bash -n "$ROOT/hosts/ex44/bootstrap.sh"
        bash -n "$ROOT/hosts/ex44/start.sh"
        bash -n "$ROOT/tests/integration/host-fixture.sh"
        bash -n "$ROOT/tests/integration/bootstrap-test.sh"
        bash -n "$ROOT/tests/start-sh-self-update-test.sh"
        bash -n "$ROOT/tests/artifact-authentication-test.sh"
        bash -n "$ROOT/tests/artifact-key-rotation-test.sh"
        bash -n "$ROOT/tests/ssh-key-rotation-test.sh"
        bash -n "$ROOT/tests/artifact-signing-provisioning-test.sh"
        bash -n "$ROOT/tests/start-sh-interface-test.sh"
        bash -n "$ROOT/tests/start-sh-runtime-test.sh"
        bash -n "$ROOT/tests/start-sh-release-test.sh"
        bash -n "$ROOT/tests/signed-release-lifecycle-test.sh"
        bash -n "$ROOT/scripts/check-host-parity.sh"
        bash -n "$ROOT/tests/host-artifact-parity-test.sh"
        bash -n "$ROOT/tests/artifact-secret-leakage-test.sh"
        bash -n "$ROOT/scripts/check-secret-leakage.sh"
        bash -n "$ROOT/scripts/check-sops-contract.sh"
        bash -n "$ROOT/ansible/run-drift.sh"
        bash -n "$ROOT/tests/ansible-drift-acceptance-test.sh"
        bash -n "$ROOT/tests/secrets-gitignore-test.sh"
        bash -n "$ROOT/tests/ansible-sops-workflow-test.sh"
        bash -n "$ROOT/tests/sops-environment-boundary-test.sh"
        bash -n "$ROOT/tests/sops-operator-boundary-test.sh"
        bash -n "$ROOT/tests/sops-recovery-drill.sh"
        bash -n "$ROOT/tests/sops-contract-test.sh"
        bash -n "$ROOT/tests/openbao-owner-routing-test.sh"
        bash -n "$ROOT/scripts/bootstrap-preflight.sh"
        bash -n "$ROOT/tests/bootstrap-platform-acceptance-test.sh"
        bash -n "$ROOT/tests/hetzner-robot-test.sh"
        bash -n "$ROOT/scripts/start-sh-release.sh"
        bash -n "$ROOT/scripts/check-hooks-path.sh"
        bash -n "$ROOT/tests/hook-activation-test.sh"
        "$ROOT/tests/start-sh-self-update-test.sh"
        "$ROOT/tests/artifact-authentication-test.sh"
        "$ROOT/tests/artifact-key-rotation-test.sh"
        "$ROOT/tests/ssh-key-rotation-test.sh"
        "$ROOT/tests/artifact-signing-provisioning-test.sh"
        "$ROOT/tests/start-sh-interface-test.sh"
        "$ROOT/tests/start-sh-runtime-test.sh"
        "$ROOT/tests/start-sh-release-test.sh"
        "$ROOT/tests/signed-release-lifecycle-test.sh"
        "$ROOT/tests/host-artifact-parity-test.sh"
        "$ROOT/tests/artifact-secret-leakage-test.sh"
        "$ROOT/scripts/check-secret-leakage.sh" --tracked --artifacts
        "$ROOT/scripts/check-sops-contract.sh"
        "$ROOT/tests/secrets-gitignore-test.sh"
        "$ROOT/tests/ansible-sops-workflow-test.sh"
        "$ROOT/tests/sops-contract-test.sh"
        "$ROOT/tests/sops-operator-boundary-test.sh"
        "$ROOT/tests/openbao-owner-routing-test.sh"
        "$ROOT/tests/ansible-drift-acceptance-test.sh"
        "$ROOT/tests/bootstrap-platform-acceptance-test.sh"
        "$ROOT/tests/hook-activation-test.sh"
        "$ROOT/hosts/ex44/sync-start-sh.sh" --check
        "$ROOT/scripts/start-sh-release.sh" --check
        "$ROOT/tests/hetzner-robot-test.sh"
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
