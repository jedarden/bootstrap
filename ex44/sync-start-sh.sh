#!/bin/bash
# Regenerates the start.sh heredoc embedded in bootstrap.sh (Step 13, "Setting
# Up start.sh for Users") from the canonical, independently-runnable
# start.sh that sits next to this script.
#
# Run this every time start.sh changes, before committing bootstrap.sh.
# See docs/plan/plan.md ADR-1: these two copies drifted (and the embedded
# heredoc extraction into the standalone file separately got corrupted) when
# they were hand-maintained; this script is the enforcement mechanism for
# "one canonical source" going forward. The repo's pre-commit hook
# (githooks/pre-commit) runs it in --check mode on every commit.
#
# Usage:
#   ./sync-start-sh.sh          # Sync start.sh -> bootstrap.sh embedded copy
#   ./sync-start-sh.sh --check  # Check only; exit 1 if out of sync (no writes)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

CHECK_MODE=false
case "${1:-}" in
    "") ;;
    --check) CHECK_MODE=true ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

bash -n start.sh || { echo "ERROR: start.sh has a syntax error, aborting sync" >&2; exit 1; }

# Export CHECK_MODE to Python
export CHECK_MODE

python3 - <<'PY'
import difflib
import os
import pathlib
import sys

repo_dir = pathlib.Path(".")
start_sh = (repo_dir / "start.sh").read_text()
bootstrap = (repo_dir / "bootstrap.sh").read_text()

begin_marker = '    cat > "/home/$user/start.sh" << \'STARTSH\'\n'
end_marker = "STARTSH\n"

begin_idx = bootstrap.find(begin_marker)
if begin_idx == -1:
    sys.exit("ERROR: could not find start.sh heredoc opening marker in bootstrap.sh")
body_start = begin_idx + len(begin_marker)

end_idx = bootstrap.find("\n" + end_marker, body_start)
if end_idx == -1:
    sys.exit("ERROR: could not find start.sh heredoc closing marker in bootstrap.sh")
body_end = end_idx + 1  # keep the newline before STARTSH

# Extract current embedded copy
current_embedded = bootstrap[body_start:body_end]

# Check mode: compare and exit without writing anything
if os.environ.get('CHECK_MODE') == 'true':
    if start_sh == current_embedded:
        sys.exit(0)  # In sync, silent success

    print("ERROR: bootstrap.sh's embedded start.sh copy is out of sync with start.sh", file=sys.stderr)
    print("Run: ./sync-start-sh.sh (from this directory), then commit both files together", file=sys.stderr)
    print("", file=sys.stderr)
    for line in difflib.unified_diff(
        current_embedded.splitlines(keepends=True),
        start_sh.splitlines(keepends=True),
        fromfile="bootstrap.sh (embedded copy)",
        tofile="start.sh (canonical)",
    ):
        sys.stderr.write(line if line.endswith("\n") else line + "\n")
    sys.exit(1)

# Sync mode: update the file
new_bootstrap = bootstrap[:body_start] + start_sh + bootstrap[body_end:]

if new_bootstrap == bootstrap:
    print("bootstrap.sh embedded copy already matches start.sh - no change")
else:
    (repo_dir / "bootstrap.sh").write_text(new_bootstrap)
    print("Regenerated embedded start.sh copy in bootstrap.sh from start.sh")
PY

# In check mode we deliberately modify nothing, so skip the post-sync checks
if $CHECK_MODE; then
    exit 0
fi

bash -n bootstrap.sh || { echo "ERROR: bootstrap.sh has a syntax error after sync" >&2; exit 1; }
echo "OK: bootstrap.sh syntax check passed"
