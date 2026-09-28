#!/usr/bin/env bash
set -Eeuo pipefail

# Run the real launcher against a disposable HOME and a private tmux server.
# Agent doubles keep this a local smoke test while preserving the runtime
# boundaries that the interface test's tmux double cannot exercise.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
START_SH="$ROOT/hosts/ex44/start.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/start-sh-runtime-test.XXXXXX")
TEST_UID=$(id -u)
CASE_TMUX_TMPDIR=""

trap 'if [[ -n "${CASE_TMUX_TMPDIR:-}" ]]; then TMUX_TMPDIR="$CASE_TMUX_TMPDIR" tmux kill-server >/dev/null 2>&1 || true; fi; rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local expected=$1 actual=$2 description=$3
    [[ "$actual" == *"$expected"* ]] ||
        fail "$description (missing $(printf '%q' "$expected"))"
}

assert_file_contains() {
    local expected=$1 path=$2 description=$3
    grep -Fq -- "$expected" "$path" ||
        fail "$description (missing $(printf '%q' "$expected"))"
}

if (( EUID == 0 )); then
    fail 'runtime smoke test must run as an unprivileged user'
fi

setup_case() {
    local name=$1

    CASE_ROOT="$TMP/$name"
    CASE_HOME="$CASE_ROOT/home"
    CASE_BIN="$CASE_ROOT/bin"
    CASE_TOOL_BIN="$CASE_ROOT/tools"
    CASE_TMUX_TMPDIR="$CASE_ROOT/tmux"
    CASE_RUNTIME_LOG="$CASE_ROOT/runtime.log"
    CASE_SUDO_LOG="$CASE_ROOT/sudo.log"
    CASE_OUTPUT="$CASE_ROOT/start.out"
    mkdir -p \
        "$CASE_HOME/.local/bin" \
        "$CASE_HOME/.tmux/plugins/tpm/bin" \
        "$CASE_BIN" \
        "$CASE_TOOL_BIN" \
        "$CASE_TMUX_TMPDIR"
    chmod 700 "$CASE_TMUX_TMPDIR"

    # Keep host-installed Claude/Codex binaries out of PATH. The launcher
    # still gets the ordinary utilities it needs through explicit symlinks.
    local tool
    for tool in bash env sh readlink dirname mktemp grep sort head mkdir ln \
        tmux sudo id sleep script cat; do
        ln -s "$(command -v "$tool")" "$CASE_TOOL_BIN/$tool"
    done
    PATH_VALUE="$CASE_HOME/.local/bin:$CASE_BIN:$CASE_TOOL_BIN"

    cp "$START_SH" "$CASE_HOME/start.sh"
    chmod +x "$CASE_HOME/start.sh"
    ln -s "$CASE_HOME/start.sh" "$CASE_HOME/.local/bin/start"

    # Avoid the network-backed TPM installation path while still exercising
    # the launcher's real mkdir, tmux, send-keys, and attach operations.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'exit 0' > "$CASE_HOME/.tmux/plugins/tpm/bin/install_plugins"
    chmod +x "$CASE_HOME/.tmux/plugins/tpm/bin/install_plugins"

    # The selected agent records the uid, cwd, and argv from inside the real
    # tmux pane, then stays alive until the test tears the session down.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -Eeuo pipefail' \
        'agent=${0##*/}' \
        'phase=runtime' \
        'if [[ "${1:-}" == --version ]]; then phase=version; fi' \
        'printf "phase=%s agent=%s uid=%s pwd=%s args=%s\\n" "$phase" "$agent" "$(id -u)" "$PWD" "$*" >> "$CASE_RUNTIME_LOG"' \
        'if [[ "$phase" == version ]]; then printf "%s 1.0.0\\n" "$agent"; exit 0; fi' \
        'while :; do sleep 1; done' > "$CASE_BIN/agent"
    chmod +x "$CASE_BIN/agent"
    ln -s agent "$CASE_BIN/claude"
    ln -s agent "$CASE_BIN/codex"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\\n" "1.0.0"' > "$CASE_BIN/curl"
    chmod +x "$CASE_BIN/curl"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${1:-}" == view ]]; then printf "%s\\n" "1.0.0"; fi' > "$CASE_BIN/npm"
    chmod +x "$CASE_BIN/npm"

    # The real launcher treats OOM protection as best-effort. This double
    # proves the smoke test does not require root or passwordless sudo.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\\n" "$*" >> "$CASE_SUDO_LOG"' \
        'exit 1' > "$CASE_BIN/sudo"
    chmod +x "$CASE_BIN/sudo"
}

tmux_case_command() {
    TMUX_TMPDIR="$CASE_TMUX_TMPDIR" tmux "$@"
}

stop_case_server() {
    tmux_case_command kill-server >/dev/null 2>&1 || true
}

run_tmux_case() {
    local agent=$1
    local expected_args
    if [[ "$agent" == claude ]]; then
        expected_args='--dangerously-skip-permissions --model sonnet'
    else
        expected_args='--dangerously-bypass-approvals-and-sandbox'
    fi

    setup_case "$agent"
    export CASE_RUNTIME_LOG CASE_SUDO_LOG
    [[ "$(PATH="$PATH_VALUE" command -v start)" == "$CASE_HOME/.local/bin/start" ]] ||
        fail "$agent runtime did not resolve the deployed start command from PATH"

    (
        export HOME="$CASE_HOME" PATH="$PATH_VALUE" TMUX_TMPDIR="$CASE_TMUX_TMPDIR"
        export TERM=xterm-256color
        unset TMUX HERDR_ENV START_SH_AGENT
        hash -r
        # tmux attach-session requires a controlling terminal. `script`
        # supplies one without coupling the test to the caller's terminal.
        script -qefc "start $agent --no-update" /dev/null
    ) > "$CASE_OUTPUT" 2>&1 &
    local start_pid=$!
    local runtime_line="phase=runtime agent=$agent uid=$TEST_UID pwd=$CASE_HOME args=$expected_args"
    local ready=false

    for _ in $(seq 1 100); do
        if grep -Fq -- "$runtime_line" "$CASE_RUNTIME_LOG" 2>/dev/null; then
            ready=true
            break
        fi
        if ! kill -0 "$start_pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    if [[ "$ready" != true ]]; then
        cat "$CASE_OUTPUT" >&2 || true
        cat "$CASE_RUNTIME_LOG" >&2 || true
        stop_case_server
        wait "$start_pid" || true
        fail "$agent did not reach the runtime agent inside tmux"
    fi

    assert_file_contains \
        "phase=version agent=$agent uid=$TEST_UID" \
        "$CASE_RUNTIME_LOG" \
        "$agent version check did not run as the unprivileged user"
    assert_file_contains 'args=--version' "$CASE_RUNTIME_LOG" \
        "$agent version check did not pass --version"

    local pane_path
    pane_path=$(tmux_case_command display-message -t alpha -p '#{pane_current_path}')
    [[ "$pane_path" == "$CASE_HOME" ]] ||
        fail "$agent tmux pane started in $pane_path instead of $CASE_HOME"

    assert_file_contains 'choom -n -1000' "$CASE_SUDO_LOG" \
        "$agent runtime did not exercise the best-effort unprivileged OOM-protection path"
    assert_contains "Creating tmux session: alpha (agent: $agent)" \
        "$(<"$CASE_OUTPUT")" "$agent was not selected through the start command"

    stop_case_server
    local start_status=0
    wait "$start_pid" || start_status=$?
    # Killing the disposable session makes an attached tmux client return 1;
    # that is the expected teardown status, distinct from a runtime failure.
    [[ "$start_status" -eq 0 || "$start_status" -eq 1 ]] ||
        fail "$agent launcher did not terminate after its tmux session ended (status $start_status)"
}

run_unavailable_case() {
    local agent=$1
    setup_case "unavailable-$agent"
    rm "$CASE_BIN/$agent"

    if [[ "$agent" == claude ]]; then
        # No installed Claude and no reachable installer means the selected
        # executable remains unavailable; no tmux side effect is acceptable.
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'exit 1' > "$CASE_BIN/curl"
        chmod +x "$CASE_BIN/curl"
    else
        # npm is present but cannot install the missing selected executable.
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'exit 1' > "$CASE_BIN/npm"
        chmod +x "$CASE_BIN/npm"
    fi

    local output status=0
    if output=$(
        export HOME="$CASE_HOME" PATH="$PATH_VALUE" TMUX_TMPDIR="$CASE_TMUX_TMPDIR"
        unset TMUX HERDR_ENV START_SH_AGENT
        hash -r
        start "$agent" --no-update
    ) 2>&1; then
        fail "$agent unexpectedly succeeded while its executable was unavailable"
    else
        status=$?
    fi
    [[ "$status" -ne 0 ]] || fail "$agent unavailable case returned success"

    if [[ "$agent" == claude ]]; then
        assert_contains 'Claude Code installation failed' "$output" \
            'missing Claude executable did not report installation failure'
    else
        assert_contains 'Codex CLI installation failed' "$output" \
            'missing Codex executable did not report installation failure'
    fi
    [[ ! -f "$CASE_HOME/.tmux/tmux.conf" ]] ||
        fail "$agent unavailable case created a tmux configuration before the agent was ready"
    if tmux_case_command has-session -t alpha >/dev/null 2>&1; then
        fail "$agent unavailable case created a tmux session before the agent was ready"
    fi
}

echo "Checking real tmux runtime as unprivileged uid $TEST_UID..."
run_tmux_case claude
run_tmux_case codex

echo 'Checking selected-agent failure handling...'
run_unavailable_case claude
run_unavailable_case codex

echo 'start.sh runtime smoke tests passed.'
