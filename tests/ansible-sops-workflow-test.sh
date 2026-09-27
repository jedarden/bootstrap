#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-ansible-sops.XXXXXX")

cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-ansible-sops."* ]]; then
        find "$WORK" -depth -delete
    fi
}
trap cleanup EXIT

die() {
    echo "Ansible SOPS workflow test failed: $*" >&2
    exit 1
}

assert_file_contains() {
    local needle=$1
    local file=$2
    grep -Fq -- "$needle" "$file" || die "missing expected contract in $file"
}

# Every file shipped beneath the secret input tree must carry the explicit
# ciphertext suffix. This also catches an accidental plaintext file in the
# shared checkout; a clean git archive has no untracked files to inspect.
if [[ -d "$ROOT/secrets/ansible" ]]; then
    while IFS= read -r -d '' file; do
        [[ "$file" == *.sops.yml ]] || die "non-SOPS Ansible file exists: ${file#$ROOT/}"
    done < <(find "$ROOT/secrets/ansible" -type f -print0)
fi

assert_file_contains '/secrets/*/*.yml' "$ROOT/.gitignore"
assert_file_contains '!/secrets/*/*.sops.yml' "$ROOT/.gitignore"
assert_file_contains 'no_log: true' "$ROOT/ansible/roles/bootstrap_drift/tasks/backup.yml"
assert_file_contains 'dest: /etc/restic/b2.env' "$ROOT/ansible/roles/bootstrap_drift/tasks/backup.yml"
assert_file_contains 'mode: "0600"' "$ROOT/ansible/roles/bootstrap_drift/tasks/backup.yml"

mkdir -m 700 "$WORK/bin" "$WORK/host"
printf '%s\n' 'fixture-only-secret' >"$WORK/input.sops.yml"

# This SOPS stub models exec-file's FIFO contract. It records the FIFO path
# only for the test, streams disposable fixture data into it, and removes it
# on every exit path. No plaintext fixture is written to a regular file by
# the workflow under test.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ ${1:-} == exec-file && $# == 3 ]] || exit 31' \
    'input=$2' \
    'command=$3' \
    '[[ -f "$input" && "$command" == *"{}"* ]] || exit 32' \
    'fifo=$MOCK_STATE_DIR/ansible-vars.fifo' \
    'rm -f "$fifo"' \
    'mkfifo "$fifo"' \
    'chmod 0600 "$fifo"' \
    'printf "%s\\n" "$fifo" >"$MOCK_STATE_DIR/fifo-path"' \
    'cleanup() { rm -f "$fifo"; }' \
    'trap cleanup EXIT' \
    'printf "%s\\n" "bootstrap_restic_env: {RESTIC_PASSWORD: fixture-only-secret}" >"$fifo" &' \
    'writer=$!' \
    'command=${command//\{\}/$fifo}' \
    'set +e' \
    'bash -c "$command"' \
    'status=$?' \
    'set -e' \
    'wait "$writer" 2>/dev/null || true' \
    'exit "$status"' >"$WORK/bin/sops"
chmod 0755 "$WORK/bin/sops"

# This Ansible stub is the managed-host fixture. It accepts only a FIFO extra
# vars source, consumes the disposable secret once, and never writes it under
# the host fixture directory.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'vars_source=' \
    'playbook=' \
    'for arg in "$@"; do' \
    '    [[ "$arg" == @* ]] && vars_source=${arg#@}' \
    '    [[ "$arg" == playbooks/*.yml ]] && playbook=$arg' \
    'done' \
    '[[ -n "$vars_source" && -p "$vars_source" ]] || exit 41' \
    'grep -Fq fixture-only-secret "$vars_source" || exit 42' \
    '[[ -n "$playbook" ]] || exit 43' \
    '[[ -z "$(find "$MOCK_HOST" -type f -print -quit)" ]] || exit 44' \
    'printf "%s\\n" "$playbook" >"$MOCK_STATE_DIR/playbook"' \
    'exit "${MOCK_ANSIBLE_EXIT:-0}"' >"$WORK/bin/ansible-playbook"
chmod 0755 "$WORK/bin/ansible-playbook"

run_wrapper() {
    SOPS_BIN="$WORK/bin/sops" \
        ANSIBLE_PLAYBOOK_BIN="$WORK/bin/ansible-playbook" \
        SOPS_ANSIBLE_VARS="$WORK/input.sops.yml" \
        MOCK_STATE_DIR="$WORK/state" \
        MOCK_HOST="$WORK/host" \
        "$ROOT/ansible/run-drift.sh" "$@"
}

mkdir -m 700 "$WORK/state"
run_wrapper check --limit fixture
[[ "$(<"$WORK/state/playbook")" == playbooks/check-drift.yml ]] ||
    die "check mode did not select check-drift.yml"
fifo_path=$(<"$WORK/state/fifo-path")
[[ ! -e "$fifo_path" ]] || die "SOPS FIFO survived a successful run"
[[ -z "$(find "$WORK/host" -type f -print -quit)" ]] ||
    die "the managed-host fixture retained a plaintext file"

set +e
MOCK_ANSIBLE_EXIT=23 \
    SOPS_BIN="$WORK/bin/sops" \
    ANSIBLE_PLAYBOOK_BIN="$WORK/bin/ansible-playbook" \
    SOPS_ANSIBLE_VARS="$WORK/input.sops.yml" \
    MOCK_STATE_DIR="$WORK/state" \
    MOCK_HOST="$WORK/host" \
    "$ROOT/ansible/run-drift.sh" apply --limit fixture
status=$?
set -e
[[ $status == 23 ]] || die "playbook failure was not returned (status $status)"
[[ ! -e "$fifo_path" ]] || die "SOPS FIFO survived a failed run"
[[ -z "$(find "$WORK/host" -type f -print -quit)" ]] ||
    die "the failed managed-host fixture retained a plaintext file"

set +e
SOPS_BIN="$WORK/bin/sops" \
    ANSIBLE_PLAYBOOK_BIN="$WORK/bin/ansible-playbook" \
    SOPS_ANSIBLE_VARS="$WORK/missing.sops.yml" \
    MOCK_STATE_DIR="$WORK/state" \
    MOCK_HOST="$WORK/host" \
    "$ROOT/ansible/run-drift.sh" check --limit fixture >/dev/null 2>&1
status=$?
set -e
[[ $status != 0 ]] || die "missing SOPS input was accepted"
[[ -z "$(find "$WORK/host" -type f -print -quit)" ]] ||
    die "missing-input failure touched the managed-host fixture"

echo "Ansible SOPS workflow test passed"
