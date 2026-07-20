#!/bin/bash
# Regenerates the start.sh heredoc embedded in bootstrap.sh (Step 13, "Setting
# Up start.sh for Users") from the canonical, independently-runnable
# ex44/start.sh.
#
# Run this every time ex44/start.sh changes, before committing bootstrap.sh.
# See docs/plan/plan.md ADR-1: these two copies drifted (and the embedded
# heredoc extraction into the standalone file separately got corrupted) when
# they were hand-maintained; this script is the enforcement mechanism for
# "one canonical source" going forward.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

bash -n start.sh || { echo "ERROR: ex44/start.sh has a syntax error, aborting sync" >&2; exit 1; }

python3 - "$@" <<'PY'
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

# Indent each line of start.sh by 4 spaces to match the existing heredoc body
# (it's written inside `for user in ...; do ... done`), except we do NOT want
# to alter start.sh's own content/indentation - the original embedded copy
# was NOT re-indented (it's a heredoc, indentation inside is literal), so we
# insert start.sh verbatim.
new_bootstrap = bootstrap[:body_start] + start_sh + bootstrap[body_end:]

if new_bootstrap == bootstrap:
    print("bootstrap.sh embedded copy already matches ex44/start.sh - no change")
else:
    (repo_dir / "bootstrap.sh").write_text(new_bootstrap)
    print("Regenerated embedded start.sh copy in bootstrap.sh from ex44/start.sh")
PY

bash -n bootstrap.sh || { echo "ERROR: bootstrap.sh has a syntax error after sync" >&2; exit 1; }
echo "OK: bootstrap.sh syntax check passed"
