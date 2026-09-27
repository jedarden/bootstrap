#!/usr/bin/env bash
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
bash -n bootstrap.sh || { echo "ERROR: bootstrap.sh has a syntax error, aborting sync" >&2; exit 1; }

# Export CHECK_MODE to Python
export CHECK_MODE

python3 - <<'PY'
import difflib
import os
import pathlib
import re
import sys

repo_dir = pathlib.Path(".")
start_sh = (repo_dir / "start.sh").read_text()
bootstrap = (repo_dir / "bootstrap.sh").read_text()
version_file = (repo_dir / "start.sh.version").read_text()

version_pattern = re.compile(r'^START_SH_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$', re.MULTILINE)


def extract_version(text, label):
    matches = version_pattern.findall(text)
    if len(matches) != 1:
        sys.exit(f"ERROR: {label} must contain exactly one START_SH_VERSION assignment")
    return matches[0]


standalone_version = extract_version(start_sh, "start.sh")
embedded_version = extract_version(bootstrap, "bootstrap.sh embedded start.sh")
version_lines = version_file.splitlines()
if len(version_lines) != 1 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version_lines[0]):
    sys.exit("ERROR: start.sh.version must contain exactly one MAJOR.MINOR.PATCH line")
advertised_version = version_lines[0]
if standalone_version != advertised_version:
    sys.exit(
        "ERROR: version mismatch: "
        f"start.sh={standalone_version}, "
        f"start.sh.version={advertised_version}"
    )
if os.environ.get('CHECK_MODE') == 'true' and embedded_version != standalone_version:
    sys.exit(
        "ERROR: version mismatch: "
        f"start.sh={standalone_version}, "
        f"bootstrap.sh={embedded_version}, "
        f"start.sh.version={advertised_version}"
    )

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

new_embedded_version = extract_version(new_bootstrap, "generated bootstrap.sh embedded start.sh")
if new_embedded_version != standalone_version:
    sys.exit(
        "ERROR: generated bootstrap.sh version "
        f"{new_embedded_version} disagrees with start.sh version {standalone_version}"
    )

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
