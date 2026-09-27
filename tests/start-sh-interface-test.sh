#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the user-facing `start` command through its PATH-installed symlink.
# The disposable HOME and command doubles make the test independent of a live
# tmux server, installed agents, npm, network access, and the operator's HOME.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
START_SH="$ROOT/hosts/ex44/start.sh"
BASH_BIN_DIR=$(dirname "$(command -v bash)")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/start-sh-interface-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local expected=$1 actual=$2 description=$3
    [[ "$actual" == *"$expected"* ]] ||
        fail "$description (missing $(printf '%q' "$expected"))"
}

assert_not_contains() {
    local unexpected=$1 actual=$2 description=$3
    [[ "$actual" != *"$unexpected"* ]] ||
        fail "$description (found $(printf '%q' "$unexpected"))"
}

assert_file_contains() {
    local expected=$1 path=$2 description=$3
    grep -Fq -- "$expected" "$path" ||
        fail "$description (missing $(printf '%q' "$expected"))"
}

assert_file_not_exists() {
    local path=$1 description=$2
    [[ ! -e "$path" ]] || fail "$description ($path exists)"
}

setup_case() {
    local name=$1

    CASE_ROOT="$TMP/$name"
    CASE_HOME="$CASE_ROOT/home"
    FAKE_BIN="$CASE_ROOT/bin"
    LAUNCHER="$CASE_HOME/start.sh"
    PATH_VALUE="$CASE_HOME/.local/bin:$FAKE_BIN:$BASH_BIN_DIR:/usr/local/bin:/usr/bin:/bin"
    FAKE_TMUX_LOG="$CASE_ROOT/tmux.log"
    FAKE_AGENT_LOG="$CASE_ROOT/agent.log"

    mkdir -p \
        "$CASE_HOME/.local/bin" \
        "$CASE_HOME/.tmux/plugins/tpm/bin" \
        "$FAKE_BIN"
    cp "$START_SH" "$LAUNCHER"
    chmod +x "$LAUNCHER"
    ln -s "$LAUNCHER" "$CASE_HOME/.local/bin/start"

    # Existing plugin-manager files keep the launcher on the local command
    # path; no clone or plugin installation is part of this interface test.
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
        > "$CASE_HOME/.tmux/plugins/tpm/bin/install_plugins"
    chmod +x "$CASE_HOME/.tmux/plugins/tpm/bin/install_plugins"

    # Both agent doubles report a stable installed version and record real
    # launches. The launcher uses the basename so one script can stand in for
    # both commands without masking which agent was selected.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'agent=${0##*/}' \
        'printf "%s" "$agent" >> "$FAKE_AGENT_LOG"' \
        'for arg in "$@"; do printf " <%s>" "$arg" >> "$FAKE_AGENT_LOG"; done' \
        'printf "\n" >> "$FAKE_AGENT_LOG"' \
        'if [[ "${1:-}" == --version ]]; then' \
        '    printf "%s 1.0.0\n" "$agent"' \
        'else' \
        '    printf "%s" "$agent"' \
        '    for arg in "$@"; do printf " <%s>" "$arg"; done' \
        '    printf "\n"' \
        'fi' > "$FAKE_BIN/agent"
    chmod +x "$FAKE_BIN/agent"
    ln -s agent "$FAKE_BIN/claude"
    ln -s agent "$FAKE_BIN/codex"

    # The launcher only needs a successful latest-version lookup for this
    # test; --no-update disables the separate launcher self-update request.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "1.0.0\n"' > "$FAKE_BIN/curl"
    chmod +x "$FAKE_BIN/curl"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${1:-}" == view ]]; then' \
        '    printf "1.0.0\n"' \
        'fi' > "$FAKE_BIN/npm"
    chmod +x "$FAKE_BIN/npm"

    # Record every tmux argv. Bare-shell operations return the values the
    # launcher expects: no existing sessions, a stable server PID, and a
    # successful attach.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '{' \
        '    printf "tmux"' \
        '    for arg in "$@"; do printf " <%s>" "$arg"; done' \
        '    printf "\n"' \
        '} >> "$FAKE_TMUX_LOG"' \
        'case "${1:-}" in' \
        '    has-session|list-sessions) exit 1 ;;' \
        '    display-message) printf "4242\n" ;;' \
        'esac' > "$FAKE_BIN/tmux"
    chmod +x "$FAKE_BIN/tmux"

    # OOM protection is best-effort; make its absence deterministic and quiet.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'exit 1' > "$FAKE_BIN/sudo"
    chmod +x "$FAKE_BIN/sudo"
}

run_start() {
    local herdr=$1
    shift

    local output
    if ! output=$(
        {
            export HOME="$CASE_HOME" PATH="$PATH_VALUE"
            export FAKE_TMUX_LOG FAKE_AGENT_LOG
            unset TMUX START_SH_AGENT
            if [[ "$herdr" == true ]]; then
                export HERDR_ENV=start-interface-test
            else
                unset HERDR_ENV
            fi
            hash -r
            start "$@" < /dev/null
        } 2>&1
    ); then
        printf '%s\n' "$output" >&2
        fail "launcher invocation failed: $*"
    fi
    CASE_OUTPUT=$output
}

run_invalid() {
    local name=$1
    shift

    setup_case "$name"
    local output
    if output=$(
        {
            export HOME="$CASE_HOME" PATH="$PATH_VALUE"
            export FAKE_TMUX_LOG FAKE_AGENT_LOG
            unset TMUX HERDR_ENV START_SH_AGENT
            hash -r
            start "$@" < /dev/null
        } 2>&1
    ); then
        printf '%s\n' "$output" >&2
        fail "invalid launcher invocation unexpectedly succeeded: $*"
    fi
    CASE_OUTPUT=$output
}

echo 'Checking the PATH-installed command and non-interactive default...'
setup_case default
[[ "$(PATH="$PATH_VALUE" command -v start)" == "$CASE_HOME/.local/bin/start" ]] ||
    fail 'start was not resolved from the PATH-installed symlink'
run_start false --no-update
assert_contains 'No TTY and no --agent/START_SH_AGENT given - defaulting to claude.' \
    "$CASE_OUTPUT" 'missing non-interactive claude default'
assert_contains 'Creating tmux session: alpha (agent: claude)' \
    "$CASE_OUTPUT" 'default did not select claude for tmux'
assert_file_contains \
    'tmux <has-session> <-t> <alpha>' "$FAKE_TMUX_LOG" \
    'default did not probe the first tmux session name'
assert_file_contains \
    'tmux <-f> <'"$CASE_HOME"'/.tmux/tmux.conf> <new-session> <-d> <-s> <alpha>' \
    "$FAKE_TMUX_LOG" 'default did not create a tmux session'
assert_file_contains \
    'unset CLAUDECODE && exec claude --dangerously-skip-permissions --model sonnet' \
    "$FAKE_TMUX_LOG" 'default did not send the Claude command to tmux'
assert_not_contains 'exec codex' "$(<"$FAKE_TMUX_LOG")" \
    'default unexpectedly dispatched Codex'
[[ "$(readlink "$CASE_HOME/.local/bin/start")" == "$LAUNCHER" ]] ||
    fail 'PATH command symlink points at the wrong deployed file'

echo 'Checking positional Codex dispatch through tmux...'
setup_case codex-tmux
run_start false codex --no-update
assert_contains 'Creating tmux session: alpha (agent: codex)' \
    "$CASE_OUTPUT" 'positional codex did not select Codex'
assert_file_contains \
    'unset CLAUDECODE && exec codex --dangerously-bypass-approvals-and-sandbox' \
    "$FAKE_TMUX_LOG" 'positional codex was not sent to tmux'
assert_not_contains 'exec claude' "$(<"$FAKE_TMUX_LOG")" \
    'positional codex unexpectedly dispatched Claude'

echo 'Checking direct agent execution inside a herdr pane...'
setup_case codex-herdr
run_start true codex --no-update
assert_contains 'Detected herdr pane unknown - skipping nested tmux session.' \
    "$CASE_OUTPUT" 'herdr pane was not detected'
assert_contains 'codex <--dangerously-bypass-approvals-and-sandbox>' \
    "$(<"$FAKE_AGENT_LOG")" 'selected agent was not executed directly'
assert_file_not_exists "$FAKE_TMUX_LOG" \
    'herdr dispatch unexpectedly invoked tmux'

echo 'Checking invalid agent arguments...'
run_invalid unknown-agent nope --no-update
assert_contains "Error: unknown agent 'nope' (expected claude or codex)" \
    "$CASE_OUTPUT" 'unknown positional agent was accepted'
assert_file_not_exists "$FAKE_TMUX_LOG" \
    'unknown positional agent reached tmux'

run_invalid duplicate-agent claude codex --no-update
assert_contains 'Error: agent given twice: claude and codex' \
    "$CASE_OUTPUT" 'duplicate positional agents were accepted'
assert_file_not_exists "$FAKE_AGENT_LOG" \
    'duplicate positional agents reached an agent'

run_invalid unsupported-flag --agent llama --no-update
assert_contains "Error: unsupported --agent 'llama' (expected claude or codex)" \
    "$CASE_OUTPUT" 'unsupported --agent value was accepted'
assert_file_not_exists "$FAKE_TMUX_LOG" \
    'unsupported --agent value reached tmux'

echo 'start command interface regression tests passed.'
