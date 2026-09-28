#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sync-start-sh.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_fixture() {
    local destination="$1"
    mkdir -p "$destination"
    cp -p \
        "$ROOT/hosts/ex44/sync-start-sh.sh" \
        "$ROOT/hosts/ex44/start.sh" \
        "$ROOT/hosts/ex44/start.sh.version" \
        "$ROOT/hosts/ex44/bootstrap.sh" \
        "$destination/"
}

expect_failure() {
    local expected_status="$1"
    local description="$2"
    shift 2

    local actual_status=0
    if "$@"; then
        fail "$description unexpectedly succeeded"
    else
        actual_status=$?
    fi
    [[ "$actual_status" -eq "$expected_status" ]] ||
        fail "$description exited $actual_status, expected $expected_status"
}

assert_unchanged() {
    local before="$1"
    local after="$2"
    diff -r -q "$before" "$after" >/dev/null ||
        fail "$3 modified files"
}

FIXTURE="$TMP/hosts/lab"
make_fixture "$FIXTURE"

# Give the fixture lineage distinctive, non-secret values so propagation is
# checked against the inputs rather than the production host's current values.
python3 - "$FIXTURE/start.sh" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
text, url_count = re.subn(
    r'^REPO_URL="[^"\n]+"$',
    'REPO_URL="https://example.invalid/bootstrap/hosts/lab"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if url_count != 1:
    raise SystemExit("fixture start.sh did not have one repository URL")
text, key_id_count = re.subn(
    r'^ARTIFACT_TRUSTED_KEY_ID="[^"]+"$',
    'ARTIFACT_TRUSTED_KEY_ID="sync-regression-key"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if key_id_count != 1:
    raise SystemExit("fixture start.sh did not have one trust-anchor ID")
text, public_key_count = re.subn(
    r'^MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYE.*$',
    "SYNC_REGRESSION_TRUST_ANCHOR_DATA",
    text,
    count=1,
    flags=re.MULTILINE,
)
if public_key_count != 1:
    raise SystemExit("fixture start.sh did not have the expected public-key data")
path.write_text(text)
PY

(
    cd "$FIXTURE"
    ./sync-start-sh.sh
)

python3 - "$FIXTURE/start.sh" "$FIXTURE/bootstrap.sh" <<'PY'
import pathlib
import re
import sys

start = pathlib.Path(sys.argv[1]).read_text()
bootstrap = pathlib.Path(sys.argv[2]).read_text()
begin_marker = "    cat > \"/home/$user/start.sh\" << 'STARTSH'\n"
end_marker = "\nSTARTSH\n"
begin = bootstrap.find(begin_marker)
if begin < 0:
    raise SystemExit("bootstrap.sh is missing the embedded launcher opener")
body_start = begin + len(begin_marker)
end = bootstrap.find(end_marker, body_start)
if end < 0:
    raise SystemExit("bootstrap.sh is missing the embedded launcher closer")
embedded = bootstrap[body_start : end + 1]
if embedded != start:
    raise SystemExit("bootstrap.sh launcher does not exactly match start.sh")

repo_pattern = re.compile(r'^REPO_URL="[^"\n]+"\n', re.MULTILINE)
trust_pattern = re.compile(
    r'^ARTIFACT_TRUSTED_KEY_ID=.*?^ARTIFACT_TRUSTED_PUBLIC_KEYS=[^\n]*\n',
    re.MULTILINE | re.DOTALL,
)
start_repo = repo_pattern.findall(start)
top_level = bootstrap[:begin]
bootstrap_repo = repo_pattern.findall(top_level)
if len(start_repo) != 1 or bootstrap_repo != start_repo:
    raise SystemExit("bootstrap.sh top-level repository URL does not match start.sh")
start_trust = trust_pattern.search(start)
bootstrap_trust = trust_pattern.search(top_level)
if start_trust is None or bootstrap_trust is None:
    raise SystemExit("could not locate both trust-anchor blocks")
if bootstrap_trust.group(0) != start_trust.group(0):
    raise SystemExit("bootstrap.sh top-level trust anchor does not match start.sh")
if "SYNC_REGRESSION_TRUST_ANCHOR_DATA" not in bootstrap_trust.group(0):
    raise SystemExit("fixture trust-anchor data was not propagated")
PY

cp -a "$FIXTURE" "$TMP/check-clean-before"
(
    cd "$FIXTURE"
    ./sync-start-sh.sh --check
)
assert_unchanged "$TMP/check-clean-before" "$FIXTURE" "successful --check"

CHECK_FIXTURE="$TMP/check-mismatch"
cp -a "$FIXTURE" "$CHECK_FIXTURE"
python3 - "$CHECK_FIXTURE/bootstrap.sh" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = 'REPO_URL="https://example.invalid/bootstrap/hosts/lab"'
new = 'REPO_URL="https://example.invalid/bootstrap/hosts/stale"'
if text.count(old) < 2:
    raise SystemExit("fixture does not contain both propagated repository URLs")
# Keep the top-level value current and introduce drift only in the embedded copy.
before, marker, after = text.partition("    cat > \"/home/$user/start.sh\" << 'STARTSH'\n")
if not marker or old not in after:
    raise SystemExit("could not locate the embedded fixture URL")
path.write_text(before + marker + after.replace(old, new, 1))
PY
cp -a "$CHECK_FIXTURE" "$TMP/check-mismatch-before"
expect_failure 1 "out-of-sync --check" bash -c 'cd "$1" && ./sync-start-sh.sh --check' _ "$CHECK_FIXTURE"
assert_unchanged "$TMP/check-mismatch-before" "$CHECK_FIXTURE" "failing --check"

SYNTAX_FIXTURE="$TMP/syntax-failure"
make_fixture "$SYNTAX_FIXTURE"
printf '\nif then\n' >> "$SYNTAX_FIXTURE/start.sh"
cp -p "$SYNTAX_FIXTURE/bootstrap.sh" "$TMP/bootstrap-before-syntax-failure"
expect_failure 1 "invalid launcher syntax" bash -c 'cd "$1" && ./sync-start-sh.sh' _ "$SYNTAX_FIXTURE"
cmp -s "$TMP/bootstrap-before-syntax-failure" "$SYNTAX_FIXTURE/bootstrap.sh" ||
    fail "invalid launcher syntax modified bootstrap.sh"

TRUST_FIXTURE="$TMP/trust-failure"
make_fixture "$TRUST_FIXTURE"
python3 - "$TRUST_FIXTURE/start.sh" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text, count = re.subn(
    r'^ARTIFACT_TRUSTED_KEY_ID=.*?^ARTIFACT_TRUSTED_PUBLIC_KEYS=.*$\n?',
    "",
    path.read_text(),
    count=1,
    flags=re.MULTILINE | re.DOTALL,
)
if count != 1:
    raise SystemExit("could not remove the fixture trust-anchor block")
path.write_text(text)
PY
cp -p "$TRUST_FIXTURE/bootstrap.sh" "$TMP/bootstrap-before-trust-failure"
expect_failure 1 "missing trust anchor" bash -c 'cd "$1" && ./sync-start-sh.sh 2>"$2"' _ "$TRUST_FIXTURE" "$TMP/trust-failure.stderr"
grep -Fq "could not find the artifact trust-anchor block in start.sh" "$TMP/trust-failure.stderr" ||
    fail "missing trust anchor did not fail with the expected validation error"
cmp -s "$TMP/bootstrap-before-trust-failure" "$TRUST_FIXTURE/bootstrap.sh" ||
    fail "missing trust anchor modified bootstrap.sh"

USAGE_FIXTURE="$TMP/usage-failure"
make_fixture "$USAGE_FIXTURE"
cp -p "$USAGE_FIXTURE/bootstrap.sh" "$TMP/bootstrap-before-usage-failure"
expect_failure 2 "unsupported synchronizer argument" bash -c 'cd "$1" && ./sync-start-sh.sh --unsupported' _ "$USAGE_FIXTURE"
cmp -s "$TMP/bootstrap-before-usage-failure" "$USAGE_FIXTURE/bootstrap.sh" ||
    fail "unsupported synchronizer argument modified bootstrap.sh"

echo 'sync-start-sh regression tests passed.'
