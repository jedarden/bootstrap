#!/usr/bin/env bash
set -Eeuo pipefail

# Verify that this checkout is using the versioned hooks. A git archive has no
# local config, so the check is intentionally skipped when run outside a
# working tree; the disposable activation test still covers the failure modes.

ROOT=${1:-$(pwd)}

if ! git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "Hook activation check skipped: $ROOT is not a Git checkout."
    exit 0
fi

hooks_path=$(git -C "$ROOT" config --local --get core.hooksPath || true)
if [[ "$hooks_path" != "githooks" ]]; then
    if [[ -n "$hooks_path" ]]; then
        echo "ERROR: core.hooksPath is '$hooks_path'; expected 'githooks'." >&2
    else
        echo "ERROR: core.hooksPath is unset; activate the versioned hook with:" >&2
        echo "  git config core.hooksPath githooks" >&2
    fi
    exit 1
fi

echo "Hook activation verified: core.hooksPath=githooks"
