#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise start.sh's self-update path with local command doubles. The real
# launcher is copied into a disposable HOME so every case can inspect whether
# a failed update left the working file usable and unchanged.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
START_SH="$ROOT/hosts/ex44/start.sh"
BASH_BIN_DIR=$(dirname "$(command -v bash)")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/start-sh-self-update.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local expected=$1 actual=$2 description=$3
    [[ "$actual" == *"$expected"* ]] || fail "$description (missing $(printf '%q' "$expected"))"
}

assert_file_contains() {
    local expected=$1 path=$2 description=$3
    grep -Fq -- "$expected" "$path" || fail "$description (missing $(printf '%q' "$expected") in $path)"
}

assert_file_not_contains() {
    local unexpected=$1 path=$2 description=$3
    ! grep -Fq -- "$unexpected" "$path" || fail "$description (found $(printf '%q' "$unexpected") in $path)"
}

assert_unchanged() {
    cmp -s "$LAUNCHER" "$ORIGINAL" || fail "${1:-launcher changed unexpectedly}"
}

setup_case() {
    local name=$1 mode=$2

    CASE_ROOT="$TMP/$name"
    CASE_HOME="$CASE_ROOT/home"
    FAKE_BIN="$CASE_ROOT/bin"
    LAUNCHER="$CASE_HOME/start.sh"
    ORIGINAL="$CASE_ROOT/original-start.sh"
    PAYLOAD_FILE="$CASE_ROOT/remote-start.sh"
    CURL_LOG="$CASE_ROOT/curl.log"
    MV_LOG="$CASE_ROOT/mv.log"

    mkdir -p "$CASE_HOME" "$FAKE_BIN"
    cp "$START_SH" "$LAUNCHER"
    chmod +x "$LAUNCHER"
    cp "$LAUNCHER" "$ORIGINAL"

    # The valid payload exits after the re-exec and prints the original flags,
    # proving that a successful update reaches the new launcher.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "UPDATED_LAUNCHER"' \
        'printf " <%s>" "$@"' \
        'printf "\\n"' > "$PAYLOAD_FILE"
    chmod +x "$PAYLOAD_FILE"

    # curl serves either release metadata or the selected launcher payload.
    # Unknown URLs intentionally fail so the normal agent-version check cannot
    # reach the network during this test.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'url="${!#}"' \
        'printf "%s\\n" "$url" >> "$FAKE_CURL_LOG"' \
        'case "$url" in' \
        '  */start.sh.version)' \
        '    case "$FAKE_CURL_MODE" in' \
        '      version-unavailable) exit 22 ;;' \
        '      version-malformed) printf "%s\\n" "not-a-version" ;;' \
        '      *) printf "%s\\n" "999.0.0" ;;' \
        '    esac' \
        '    ;;' \
        '  */start.sh)' \
        '    case "$FAKE_CURL_MODE" in' \
        '      payload-unavailable) exit 22 ;;' \
        '      payload-empty) : ;;' \
        '      payload-malformed) printf "%s\\n" "#!/usr/bin/env bash" "if (" ;;' \
        '      *) cat "$FAKE_PAYLOAD_FILE" ;;' \
        '    esac' \
        '    ;;' \
        '  *) exit 22 ;;' \
        'esac' > "$FAKE_BIN/curl"
    chmod +x "$FAKE_BIN/curl"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "${1:-}" == --version ]]; then' \
        '    printf "%s\\n" "claude 1.0.0"' \
        'else' \
        '    printf "AGENT_LAUNCHED"' \
        '    printf " %s" "$@"' \
        '    printf "\\n"' \
        'fi' > "$FAKE_BIN/claude"
    chmod +x "$FAKE_BIN/claude"

    # Record the replacement operation and optionally fail it. A valid update
    # must use one same-directory mv, rather than streaming into SELF_PATH.
    local mv_command
    mv_command=$(command -v mv)
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "args=%s\\nsource=%s\\ntarget=%s\\n" "$*" "${2:-}" "${3:-}" > "$FAKE_MV_LOG"' \
        'if [[ "$FAKE_MV_FAILURE" == true ]]; then exit 1; fi' \
        "exec \"$mv_command\" \"\$@\"" > "$FAKE_BIN/mv"
    chmod +x "$FAKE_BIN/mv"

    CASE_MODE="$mode"
}

run_case() {
    local name=$1 mode=$2
    setup_case "$name" "$mode"

    local output
    if ! output=$(
        HOME="$CASE_HOME" \
        PATH="$FAKE_BIN:$BASH_BIN_DIR:/usr/local/bin:/usr/bin:/bin" \
        HERDR_ENV=self-update-test \
        FAKE_CURL_MODE="$CASE_MODE" \
        FAKE_CURL_LOG="$CURL_LOG" \
        FAKE_PAYLOAD_FILE="$PAYLOAD_FILE" \
        FAKE_MV_LOG="$MV_LOG" \
        FAKE_MV_FAILURE=false \
        "$LAUNCHER" --agent claude 2>&1
    ); then
        printf '%s\n' "$output" >&2
        fail "$name launcher invocation failed"
    fi

    CASE_OUTPUT="$output"
}

echo 'Checking tmux OOM hardening in both launcher copies...'
for launcher in "$START_SH" "$ROOT/hosts/ex44/bootstrap.sh"; do
    assert_file_contains \
        'sudo -n choom -n -1000 -p "$SERVER_PID"' \
        "$launcher" \
        'tmux server OOM protection drifted'
    assert_file_contains \
        'set -g history-limit 2000' \
        "$launcher" \
        'tmux history limit drifted'
    assert_file_contains \
        'AGENT_ARGV=(claude --dangerously-skip-permissions --model sonnet)' \
        "$launcher" \
        'Claude model pin drifted'
    assert_file_not_contains \
        'set -g history-limit 10000' \
        "$launcher" \
        'legacy tmux history limit was reintroduced'
done

echo 'Checking successful update and atomic replacement...'
run_case success success
assert_contains 'UPDATED_LAUNCHER <--no-update> <--agent> <claude>' "$CASE_OUTPUT" \
    'successful update did not re-exec the fetched launcher with original flags'
cmp -s "$LAUNCHER" "$PAYLOAD_FILE" || fail 'successful update did not install the fetched payload'
[[ -x "$LAUNCHER" ]] || fail 'successful update did not preserve launcher executability'
[[ -f "$MV_LOG" ]] || fail 'successful update did not replace through mv'
source_path=$(sed -n 's/^source=//p' "$MV_LOG")
target_path=$(sed -n 's/^target=//p' "$MV_LOG")
[[ "$target_path" == "$LAUNCHER" ]] || fail 'atomic replacement targeted the wrong launcher'
[[ "$source_path" == "$LAUNCHER.tmp."* ]] || fail 'replacement source was not a launcher-local temporary file'
[[ "$(dirname "$source_path")" == "$(dirname "$LAUNCHER")" ]] || fail 'replacement temporary file was not on the launcher filesystem'

echo 'Checking unavailable and malformed release metadata...'
run_case version-unavailable version-unavailable
assert_unchanged 'unavailable release metadata damaged the launcher'
assert_contains 'AGENT_LAUNCHED --dangerously-skip-permissions --model sonnet' "$CASE_OUTPUT" \
    'launcher did not continue with the installed agent after metadata became unavailable'
payload_fetches=$(grep -Ec '/start\.sh$' "$CURL_LOG" || true)
[[ "$payload_fetches" -eq 0 ]] || fail 'unavailable metadata unexpectedly fetched a launcher payload'

run_case version-malformed version-malformed
assert_unchanged 'malformed release metadata damaged the launcher'
payload_fetches=$(grep -Ec '/start\.sh$' "$CURL_LOG" || true)
[[ "$payload_fetches" -eq 0 ]] || fail 'malformed metadata unexpectedly fetched a launcher payload'

echo 'Checking unavailable and syntax-invalid launcher payloads...'
run_case payload-unavailable payload-unavailable
assert_unchanged 'unavailable launcher payload damaged the launcher'
assert_contains 'AGENT_LAUNCHED --dangerously-skip-permissions --model sonnet' "$CASE_OUTPUT" \
    'launcher did not continue with the installed agent after payload fetch failure'
payload_fetches=$(grep -Ec '/start\.sh$' "$CURL_LOG" || true)
[[ "$payload_fetches" -eq 1 ]] || fail 'unavailable payload did not fetch the launcher exactly once'

run_case payload-empty payload-empty
assert_unchanged 'empty launcher payload damaged the launcher'
assert_contains 'AGENT_LAUNCHED --dangerously-skip-permissions --model sonnet' "$CASE_OUTPUT" \
    'launcher did not remain usable after an empty payload'

run_case payload-malformed payload-malformed
assert_unchanged 'syntax-invalid launcher payload damaged the launcher'
assert_contains 'failed syntax check, keeping current version' "$CASE_OUTPUT" \
    'syntax-gate failure was not reported'
assert_contains 'AGENT_LAUNCHED --dangerously-skip-permissions --model sonnet' "$CASE_OUTPUT" \
    'launcher did not remain usable after a syntax-gate failure'
[[ ! -f "$MV_LOG" ]] || fail 'syntax-invalid payload reached the replacement step'

echo 'Checking replacement failure preserves the existing launcher...'
setup_case replacement-failure success
output=$(
    HOME="$CASE_HOME" \
    PATH="$FAKE_BIN:$BASH_BIN_DIR:/usr/local/bin:/usr/bin:/bin" \
    HERDR_ENV=self-update-test \
    FAKE_CURL_MODE="$CASE_MODE" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_PAYLOAD_FILE="$PAYLOAD_FILE" \
    FAKE_MV_LOG="$MV_LOG" \
    FAKE_MV_FAILURE=true \
    "$LAUNCHER" --agent claude 2>&1
)
assert_unchanged 'failed atomic replacement damaged the launcher'
assert_contains 'could not install fetched start.sh, keeping current version' "$output" \
    'replacement failure was not reported'
assert_contains 'AGENT_LAUNCHED --dangerously-skip-permissions --model sonnet' "$output" \
    'launcher did not remain usable after replacement failure'

echo 'start.sh self-update regression tests passed.'
