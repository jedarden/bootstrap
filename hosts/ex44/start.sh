#!/usr/bin/env bash

# start.sh - Tmux + coding-agent launcher with self-update
#
# Run it as the `start` command: `start claude` or `start codex`. The deployed
# file stays ~/start.sh (the path self-update and the sync script key on);
# ~/.local/bin/start is a symlink to it, created by bootstrap.sh and, on hosts
# that predate it, by ensure_start_command below.
#
# Launches an interactive coding agent - claude or codex. On a bare shell it
# creates a phonetic-alphabet tmux session and starts the agent inside it.
# When something is already multiplexing - a herdr pane (HERDR_ENV, injected
# into every pane herdr spawns) or an existing tmux client ($TMUX) - it skips
# tmux entirely and execs the agent in the current pane instead of nesting.
#
# Canonical source: git.ardenone.com/jedarden/harnessctl.
# Releases are signed by OpenBao Transit and distributed through the read-only
# GitHub mirror. Install a deployed copy with install.sh; update it with
# `start update`. Bootstrap's launcher is a compatibility snapshot.
START_SH_VERSION="1.3.3"
REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44"
ARTIFACT_MANIFEST_FILE="artifact-manifest.txt"
ARTIFACT_SIGNATURE_FILE="artifact-manifest.sig"
ARTIFACT_TRUSTED_KEY_ID="bootstrap-rsa-2026-10"
ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEApNHGqYPfKvRpLulWXS8c
/VuKITatXEhDqrXY4/0ug9SqlZF8e/o3q6FVgbMqdRTniDOrhgx1mUcbzpFJ4Y6Z
ILcYmIEXne12A2BxHh2SF+9uXBAbwNdlEIXunybhGT4te32UKGGqRN7TdFpr6KsN
nSSNN2/WyvjL+ytqpa2KyguXkrGHSfwDdUDKDGYmL1eZHjhP2GrWxG6aI8EcMtfp
mAy/NUXxL2tOB8bGz+IPfTsycwcDqZ0mw59vQUy2+nUTnG/xQpWud6SXPMuSJoJ9
3tGGU24gz4vptPn7V/L3rGQp8Titgks0IxpwEXZV2T//wNEXBebGUGaoQfOrGSoC
AzELsxvleqZOKRJyP55Djqh5iELC9tF9yxmCmRLxYwUzYPz234Wf2E0Qi1Vo386e
VxyDwlCe9IIMEgejVkjseahaS5INmFjCoDjH7cZWY28MtTVy1u9/79n6wBkApJeQ
7AuWeqPskkNYJz18R2aRjER6/Ru+2gyXw5fnD3RbpLfzAgMBAAE=
-----END PUBLIC KEY-----
ARTIFACT_KEY
)
ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")
ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY")

# Only the user's own configuration is sourced. Values can also be exported
# directly by the calling shell. The default preserves the fleet's behavior.
START_SH_CONFIG="${START_SH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/harnessctl/config.sh}"
[[ ! -f "$START_SH_CONFIG" ]] || source "$START_SH_CONFIG"
UPDATE_REPO_URL="${START_SH_UPDATE_URL:-https://raw.githubusercontent.com/jedarden/harnessctl/main}"

usage() {
    cat <<'USAGE'
Usage: start [claude|codex] [--agent claude|codex] [--resume <session>] [--no-update] [--no-agent-update]
       start update
       start --version | --help

  claude | codex   Coding agent to launch, e.g. `start codex`. Equivalent to
                   --agent <name>; giving both with different values is an error.
  --agent <name>   Coding agent to launch: claude (default) or codex.
                   Also settable via the START_SH_AGENT environment variable.
                   If none of these is given and stdin is a TTY, start prompts;
                   with no TTY it defaults to claude so that scripted or
                   piped invocations never block on the prompt.
  --resume <id>    Resume the named session. Translates to `claude --resume
                   <id>` or `codex resume <id>` for the selected agent.
  --no-update      Skip the start self-update check.
  --no-agent-update
                   Use the installed agent without installing or updating it.
  update           Update only the launcher; do not launch or update an agent.
  --version, -v    Print the start version and exit.
  --help, -h       Show this help and exit.
USAGE
}

# Captured before parsing so a self-update re-exec can replay the user's
# original flags (notably --agent) instead of dropping them.
ORIGINAL_ARGS=("$@")

SKIP_UPDATE=false
SKIP_AGENT_UPDATE=false
UPDATE_ONLY=false
AGENT=""
POSITIONAL_AGENT=""
RESUME_SESSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v)
            echo "start v${START_SH_VERSION}"
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --no-update)
            SKIP_UPDATE=true
            shift
            ;;
        --no-agent-update)
            SKIP_AGENT_UPDATE=true
            shift
            ;;
        update)
            UPDATE_ONLY=true
            shift
            ;;
        --agent)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --agent requires a value (claude or codex)" >&2
                exit 1
            fi
            AGENT="$2"
            shift 2
            ;;
        --agent=*)
            AGENT="${1#--agent=}"
            shift
            ;;
        --resume)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "Error: --resume requires a session ID or name" >&2
                exit 1
            fi
            RESUME_SESSION="$2"
            shift 2
            ;;
        --resume=*)
            RESUME_SESSION="${1#--resume=}"
            if [[ -z "$RESUME_SESSION" ]]; then
                echo "Error: --resume requires a session ID or name" >&2
                exit 1
            fi
            shift
            ;;
        claude|codex)
            if [[ -n "$POSITIONAL_AGENT" ]]; then
                echo "Error: agent given twice: $POSITIONAL_AGENT and $1" >&2
                exit 1
            fi
            POSITIONAL_AGENT="$1"
            shift
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            echo "Error: unknown agent '$1' (expected claude or codex)" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if $UPDATE_ONLY && [[ -n "$AGENT$POSITIONAL_AGENT$RESUME_SESSION" ]]; then
    echo "Error: start update cannot be combined with an agent or resume session" >&2
    exit 1
fi

if [[ -n "$POSITIONAL_AGENT" ]]; then
    if [[ -n "$AGENT" && "$AGENT" != "$POSITIONAL_AGENT" ]]; then
        echo "Error: conflicting agents: '$POSITIONAL_AGENT' and --agent '$AGENT'" >&2
        exit 1
    fi
    AGENT="$POSITIONAL_AGENT"
fi

# Resolve symlinks so the script behaves identically whether it runs as
# ~/start.sh or through the `start` symlink on PATH (~/.local/bin/start).
# dirname of BASH_SOURCE[0] alone would name the symlink's directory, which
# would relocate the tmux config and point self-update at the wrong file.
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
[[ -n "$SELF_PATH" ]] || SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF_PATH")"
TMUX_DIR="$SCRIPT_DIR/.tmux"
TMUX_CONF="${START_SH_TMUX_CONF:-$TMUX_DIR/tmux.conf}"
TPM_DIR="$TMUX_DIR/plugins/tpm"
START_SH_WORKDIR="${START_SH_WORKDIR:-$SCRIPT_DIR}"

# Verify a signed release manifest fetched from the raw distribution path.
# The public key is embedded in this launcher so a compromised or stale raw
# response cannot choose a new verification key. A future key rotation must
# ship a transition launcher that trusts both the old and new key while the
# manifest remains signed by the old key.
verify_artifact_manifest() {
    local directory=$1 manifest="$1/$ARTIFACT_MANIFEST_FILE"
    local signature="$1/$ARTIFACT_SIGNATURE_FILE" public_key="$1/public-key.pem"
    local key_id signature_key_id signature_value manifest_version trusted_public_key

    command -v openssl >/dev/null 2>&1 || return 1
    command -v base64 >/dev/null 2>&1 || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    curl -sfL --connect-timeout 5 --max-time 20 "$UPDATE_REPO_URL/$ARTIFACT_MANIFEST_FILE" > "$manifest" 2>/dev/null || return 1
    curl -sfL --connect-timeout 5 --max-time 20 "$UPDATE_REPO_URL/$ARTIFACT_SIGNATURE_FILE" > "$signature" 2>/dev/null || return 1
    mapfile -t key_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$manifest" || true)
    [[ ${#key_ids[@]} -eq 1 ]] || return 1
    key_id=${key_ids[0]#key_id=}
    trusted_public_key=""
    for key_index in "${!ARTIFACT_TRUSTED_KEY_IDS[@]}"; do
        if [[ "$key_id" == "${ARTIFACT_TRUSTED_KEY_IDS[$key_index]}" ]]; then
            trusted_public_key="${ARTIFACT_TRUSTED_PUBLIC_KEYS[$key_index]}"
            break
        fi
    done
    [[ -n "$trusted_public_key" ]] || return 1
    printf '%s\n' "$trusted_public_key" > "$public_key"

    mapfile -t signature_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$signature" || true)
    [[ ${#signature_ids[@]} -eq 1 ]] || return 1
    signature_key_id=${signature_ids[0]#key_id=}
    [[ "$signature_key_id" == "$key_id" ]] || return 1
    mapfile -t signatures < <(grep -E '^signature=[A-Za-z0-9+/]+=*$' "$signature" || true)
    [[ ${#signatures[@]} -eq 1 ]] || return 1
    signature_value=${signatures[0]#signature=}
    printf '%s' "$signature_value" | base64 --decode > "$directory/signature.bin" 2>/dev/null || return 1
    openssl dgst -sha256 -verify "$public_key" -signature "$directory/signature.bin" "$manifest" >/dev/null 2>&1 || return 1

    [[ "$(sed -n 's/^format=//p' "$manifest")" == "harnessctl-artifacts-v1" ]] || return 1
    mapfile -t manifest_versions < <(grep -E '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$manifest" || true)
    [[ ${#manifest_versions[@]} -eq 1 ]] || return 1
    manifest_version=${manifest_versions[0]#version=}
    printf '%s\n' "$manifest_version"
}

manifest_artifact_hash() {
    local manifest=$1 artifact=$2
    mapfile -t hashes < <(grep -E "^artifact=${artifact//./\.} [0-9a-f]{64}$" "$manifest" || true)
    [[ ${#hashes[@]} -eq 1 ]] || return 1
    printf '%s\n' "${hashes[0]##* }"
}

verify_artifact_file() {
    local manifest=$1 artifact=$2 path=$3 expected actual payload_version
    expected=$(manifest_artifact_hash "$manifest" "$artifact") || return 1
    actual=$(sha256sum "$path" | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]] || return 1
    if [[ "$artifact" == "start.sh" ]]; then
        mapfile -t payload_versions < <(grep -E '^START_SH_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$path" || true)
        [[ ${#payload_versions[@]} -eq 1 ]] || return 1
        payload_version=${payload_versions[0]#START_SH_VERSION=\"}
        payload_version=${payload_version%\"}
        [[ "$payload_version" == "$(grep -E '^version=' "$manifest" | cut -d= -f2)" ]] || return 1
    fi
}

# Self-update function
check_for_self_update() {
    if $SKIP_UPDATE; then
        return 0
    fi

    # A source checkout must never be replaced by the updater.
    if command -v git >/dev/null 2>&1 &&
        git -C "$SCRIPT_DIR" ls-files --error-unmatch "$(basename "$SELF_PATH")" >/dev/null 2>&1; then
        echo "Note: source checkout detected; install a deployed copy to self-update." >&2
        $UPDATE_ONLY && return 1
        return 0
    fi

    local manifest_dir remote_version new_script
    manifest_dir=$(mktemp -d "${SELF_PATH}.manifest.XXXXXX") || return 1
    if ! remote_version=$(verify_artifact_manifest "$manifest_dir"); then
        echo "Warning: release manifest verification failed; keeping current start.sh $START_SH_VERSION" >&2
        rm -rf "$manifest_dir"
        return 1
    fi

    # Compare versions
    if [[ "$START_SH_VERSION" != "$remote_version" ]]; then
        local lowest
        lowest=$(printf '%s\n%s' "$START_SH_VERSION" "$remote_version" | sort -V | head -n1)
        if [[ "$START_SH_VERSION" == "$lowest" && "$START_SH_VERSION" != "$remote_version" ]]; then
            echo "Updating start.sh: $START_SH_VERSION -> $remote_version"
            new_script=$(mktemp "${SELF_PATH}.tmp.XXXXXX") || {
                echo "Warning: could not create a temporary start.sh update, keeping current version $START_SH_VERSION" >&2
                rm -rf "$manifest_dir"
                return 1
            }

            # Fetch beside the deployed launcher so the final rename is an
            # atomic replacement on the same filesystem. Never stream a
            # remote response directly into the working launcher.
            if ! curl -sfL --connect-timeout 5 --max-time 20 "$UPDATE_REPO_URL/start.sh" > "$new_script" 2>/dev/null; then
                rm -f "$new_script"
                rm -rf "$manifest_dir"
                return 1
            fi

            # Require the signed manifest hash and the payload's own version
            # before the syntax gate. Never install a valid-but-stale script
            # or a payload from a different release.
            if ! verify_artifact_file "$manifest_dir/$ARTIFACT_MANIFEST_FILE" "start.sh" "$new_script" ||
                [[ ! -s "$new_script" ]] || ! bash -n "$new_script" 2>/dev/null; then
                echo "Warning: fetched start.sh failed authenticity, integrity, or syntax checks; keeping current version $START_SH_VERSION" >&2
                rm -f "$new_script"
                rm -rf "$manifest_dir"
                return 1
            fi

            if ! chmod +x "$new_script" || ! mv -f "$new_script" "$SELF_PATH"; then
                echo "Warning: could not install fetched start.sh, keeping current version $START_SH_VERSION" >&2
                rm -f "$new_script"
                rm -rf "$manifest_dir"
                return 1
            fi

            rm -rf "$manifest_dir"
            echo "Updated! Restarting..."
            exec "$SELF_PATH" --no-update ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
        fi
    fi

    rm -rf "$manifest_dir"
}

if ! check_for_self_update; then
    $UPDATE_ONLY && exit 1
fi
if $UPDATE_ONLY; then
    echo "start v${START_SH_VERSION}"
    exit 0
fi

# Expose the deployed copy as the `start` command. Hosts bootstrapped before
# this existed get the link here, on the first run after self-update lands it.
# Only ever from the deployed location: linking a repo checkout would make
# self-update write through the link into a tracked file. Never replaces an
# existing `start` that is not this script.
ensure_start_command() {
    local deployed link="$HOME/.local/bin/start"
    deployed="$(readlink -f "$HOME" 2>/dev/null)/start.sh"
    [[ "$SELF_PATH" == "$deployed" ]] || return 0

    if [[ -L "$link" && "$(readlink -f "$link" 2>/dev/null)" == "$SELF_PATH" ]]; then
        return 0
    fi
    if [[ -e "$link" || -L "$link" ]]; then
        echo "Note: $link already exists and is not this script - leaving it alone." >&2
        return 0
    fi
    if mkdir -p "$HOME/.local/bin" 2>/dev/null && ln -s "$SELF_PATH" "$link" 2>/dev/null; then
        echo "Installed the 'start' command: $link -> $SELF_PATH"
    fi
}

ensure_start_command

# Phonetic alphabet for tmux session naming
PHONETIC_ALPHABET=(
    "alpha" "bravo" "charlie" "delta" "echo" "foxtrot" "golf" "hotel"
    "india" "juliet" "kilo" "lima" "mike" "november" "oscar" "papa"
    "quebec" "romeo" "sierra" "tango" "uniform" "victor" "whiskey"
    "xray" "yankee" "zulu"
)

# Find the first available phonetic name for a tmux session
find_available_session_name() {
    for name in "${PHONETIC_ALPHABET[@]}"; do
        if ! tmux has-session -t "$name" 2>/dev/null; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

# Install TPM (Tmux Plugin Manager) and plugins
install_tpm() {
    if [[ ! -d "$TPM_DIR" ]]; then
        echo "Installing Tmux Plugin Manager..."
        git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
    fi
}

# Install tmux plugins
install_plugins() {
    if [[ -x "$TPM_DIR/bin/install_plugins" ]]; then
        echo "Installing tmux plugins..."
        "$TPM_DIR/bin/install_plugins"
    fi
}

# Install or update Claude Code using native installer
install_claude_code() {
    echo "Installing/updating Claude Code via native installer..."
    if ! curl -fsSL https://claude.ai/install.sh | bash; then
        echo "Warning: Claude Code installation failed"
        return 1
    fi
}

# Get installed Claude Code version (returns empty string if not installed)
get_installed_claude_version() {
    if command -v claude &>/dev/null; then
        claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

# Get latest available Claude Code version
get_latest_claude_version() {
    local CLAUDE_RELEASES_URL="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest"
    curl -fsSL "$CLAUDE_RELEASES_URL" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Compare semantic versions: returns 0 if v1 < v2, 1 otherwise
version_lt() {
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && return 1
    local lowest
    lowest=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)
    [[ "$v1" == "$lowest" ]]
}

# Check if Claude Code needs installation or update
check_and_update_claude() {
    local installed_version latest_version

    # Ensure PATH includes common install locations
    [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
    [[ -d "$HOME/.claude/local/bin" ]] && export PATH="$HOME/.claude/local/bin:$PATH"

    installed_version=$(get_installed_claude_version)
    latest_version=$(get_latest_claude_version)

    if [[ -z "$installed_version" ]]; then
        echo "Claude Code not found. Installing..."
        install_claude_code
        # Re-add paths after install
        [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
        [[ -d "$HOME/.claude/local/bin" ]] && export PATH="$HOME/.claude/local/bin:$PATH"
        if ! command -v claude &>/dev/null; then
            echo "Error: Claude Code installation failed."
            exit 1
        fi
        echo "Claude Code installed successfully: $(get_installed_claude_version)"
    elif [[ -z "$latest_version" ]]; then
        echo "Warning: Could not fetch latest Claude Code version. Skipping update check."
        echo "Current version: $installed_version"
    elif version_lt "$installed_version" "$latest_version"; then
        echo "Claude Code update available: $installed_version -> $latest_version"
        install_claude_code
        local new_version
        new_version=$(get_installed_claude_version)
        echo "Claude Code updated: $installed_version -> $new_version"
    else
        echo "Claude Code is up to date: $installed_version"
    fi
}

# Install or update the Codex CLI. Unlike Claude Code (native installer +
# a published "latest" endpoint) Codex ships as an npm global, so presence,
# version and update all go through npm.
install_codex() {
    if ! command -v npm &>/dev/null; then
        echo "Error: npm is required to install the Codex CLI." >&2
        echo "Install Node.js/npm first, or install Codex manually:" >&2
        echo "  npm install -g @openai/codex" >&2
        return 1
    fi
    echo "Installing/updating Codex CLI via npm..."
    if ! npm install -g @openai/codex@latest; then
        echo "Warning: Codex CLI installation failed"
        return 1
    fi
}

# Get installed Codex CLI version (returns empty string if not installed)
get_installed_codex_version() {
    if command -v codex &>/dev/null; then
        codex --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

# Get latest available Codex CLI version from the npm registry
get_latest_codex_version() {
    command -v npm &>/dev/null || return 0
    npm view @openai/codex version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Check if the Codex CLI needs installation or update
check_and_update_codex() {
    local installed_version latest_version

    [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

    installed_version=$(get_installed_codex_version)
    latest_version=$(get_latest_codex_version)

    if [[ -z "$installed_version" ]]; then
        echo "Codex CLI not found. Installing..."
        install_codex
        [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
        if ! command -v codex &>/dev/null; then
            echo "Error: Codex CLI installation failed."
            exit 1
        fi
        echo "Codex CLI installed successfully: $(get_installed_codex_version)"
    elif [[ -z "$latest_version" ]]; then
        echo "Warning: Could not fetch latest Codex CLI version. Skipping update check."
        echo "Current version: $installed_version"
    elif version_lt "$installed_version" "$latest_version"; then
        echo "Codex CLI update available: $installed_version -> $latest_version"
        # A failed upgrade is not fatal when a working copy is already present.
        if install_codex; then
            echo "Codex CLI updated: $installed_version -> $(get_installed_codex_version)"
        else
            echo "Continuing with installed version $installed_version"
        fi
    else
        echo "Codex CLI is up to date: $installed_version"
    fi
}

# ---------------------------------------------------------------------------
# Agent selection
#
# Resolution order: --agent flag > $START_SH_AGENT > interactive prompt >
# claude. The prompt is only reached when stdin is a TTY, so a non-interactive
# invocation (`start.sh < /dev/null`, a scripted launch, a cron wrapper) takes
# the claude default silently rather than blocking forever inside `read`.
# ---------------------------------------------------------------------------

validate_agent() {
    case "$1" in
        claude|codex) return 0 ;;
        *) return 1 ;;
    esac
}

# Prompts on stderr, returns the chosen agent on stdout (so the caller can
# capture it with $(...) while the menu still reaches the user's terminal).
prompt_for_agent() {
    local choice
    while true; do
        printf 'Which agent?\n  1) claude  (default)\n  2) codex\n' >&2
        printf 'Choice [1]: ' >&2
        if ! read -r choice; then
            # EOF mid-prompt: take the default instead of spinning forever.
            printf '\n' >&2
            echo "claude"
            return 0
        fi
        case "$choice" in
            ""|1|claude) echo "claude"; return 0 ;;
            2|codex)     echo "codex";  return 0 ;;
            *) echo "Invalid choice: $choice" >&2 ;;
        esac
    done
}

resolve_agent() {
    if [[ -n "$AGENT" ]]; then
        if ! validate_agent "$AGENT"; then
            echo "Error: unsupported --agent '$AGENT' (expected claude or codex)" >&2
            exit 1
        fi
        return 0
    fi

    if [[ -n "${START_SH_AGENT:-}" ]]; then
        if ! validate_agent "$START_SH_AGENT"; then
            echo "Error: unsupported START_SH_AGENT '$START_SH_AGENT' (expected claude or codex)" >&2
            exit 1
        fi
        AGENT="$START_SH_AGENT"
        echo "Agent: $AGENT (from START_SH_AGENT)"
        return 0
    fi

    if [[ -t 0 ]]; then
        AGENT=$(prompt_for_agent)
    else
        AGENT="claude"
        echo "No TTY and no --agent/START_SH_AGENT given - defaulting to claude."
    fi
}

check_and_update_agent() {
    if $SKIP_AGENT_UPDATE; then
        [[ ! -d "$HOME/.local/bin" ]] || export PATH="$HOME/.local/bin:$PATH"
        if ! command -v "$AGENT" >/dev/null 2>&1; then
            echo "Error: $AGENT is not installed (--no-agent-update was requested)" >&2
            exit 1
        fi
        return 0
    fi
    case "$AGENT" in
        claude) check_and_update_claude ;;
        codex)  check_and_update_codex ;;
    esac
}

# Launch argv for the selected agent. Both run with their approval prompts
# disabled, matching what this launcher has always done for Claude Code -
# these are dedicated single-tenant boxes reached only over Tailscale.
set_agent_argv() {
    local permission_mode="${START_SH_PERMISSION_MODE:-bypass}"
    case "$permission_mode" in
        default|bypass) ;;
        *) echo "Error: START_SH_PERMISSION_MODE must be default or bypass" >&2; exit 1 ;;
    esac
    case "$AGENT" in
        claude)
            AGENT_ARGV=(claude)
            [[ "$permission_mode" != bypass ]] || AGENT_ARGV+=(--dangerously-skip-permissions)
            AGENT_ARGV+=(--model "${START_SH_CLAUDE_MODEL:-sonnet}")
            if [[ -n "$RESUME_SESSION" ]]; then
                AGENT_ARGV+=(--resume "$RESUME_SESSION")
            fi
            ;;
        codex)
            if [[ -n "$RESUME_SESSION" ]]; then
                AGENT_ARGV=(codex resume)
            else
                AGENT_ARGV=(codex)
            fi
            [[ "$permission_mode" != bypass ]] || AGENT_ARGV+=(--dangerously-bypass-approvals-and-sandbox)
            [[ -z "${START_SH_CODEX_MODEL:-}" ]] || AGENT_ARGV+=(--model "$START_SH_CODEX_MODEL")
            [[ -z "$RESUME_SESSION" ]] || AGENT_ARGV+=("$RESUME_SESSION")
            ;;
    esac
}

resolve_agent
check_and_update_agent
set_agent_argv

# Inside a herdr pane, herdr is already the multiplexer: creating a tmux
# session here would nest one inside the pane, consume a phonetic name, and
# confuse herdr's screen-manifest status detection. Exec the agent directly
# and let herdr own the pane. The ambient tmux server herdr rides on already
# carries its own OOM protection, so the choom step below is not needed here.
if [[ -n "${HERDR_ENV:-}" ]]; then
    echo "Detected herdr pane ${HERDR_PANE_ID:-unknown} - skipping nested tmux session."
    echo "Launching $AGENT in the current pane..."
    unset CLAUDECODE
    exec "${AGENT_ARGV[@]}"
fi

# Same reasoning one level down: tmux sets $TMUX in every process it spawns,
# so a non-empty value means we are already inside a tmux client. Creating a
# session here would nest a client inside a client, which tmux refuses to
# attach - the pre-v1.2.1 code created the session and launched the agent
# anyway, then failed at attach-session, leaving a detached session running an
# agent nobody was attached to (and consuming a phonetic name for it). Exec in
# the current pane instead. This is checked after the herdr branch above
# because herdr rides on the same ambient tmux server, so a herdr pane has
# both variables set and should report the more specific reason.
if [[ -n "${TMUX:-}" ]]; then
    CURRENT_SESSION=$(tmux display-message -p '#S' 2>/dev/null)
    echo "Already inside tmux (session: ${CURRENT_SESSION:-unknown}) - not nesting a new session."
    echo "Launching $AGENT in the current pane..."
    unset CLAUDECODE
    exec "${AGENT_ARGV[@]}"
fi

# Ensure tmux config directory exists
mkdir -p "$TMUX_DIR/plugins"
mkdir -p "$TMUX_DIR/resurrect"

# Create default tmux.conf if it doesn't exist
if [[ ! -f "$TMUX_CONF" ]]; then
    cat > "$TMUX_CONF" << 'TMUXCONF'
# Remap prefix to Ctrl-a
set -g prefix C-a
unbind C-b
bind C-a send-prefix

# Enable mouse
set -g mouse on

# Start windows at 1
set -g base-index 1
setw -g pane-base-index 1

# Better colors
set -g default-terminal "screen-256color"

# Faster escape
set -sg escape-time 10

# History (kept modest deliberately - see the OOM-protection note below;
# large scrollback across many sessions was a contributing factor in the
# 2026-05-25 tmux-server OOM incident)
set -g history-limit 2000

# Split panes with | and -
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Reload config
bind r source-file ~/.tmux.conf \; display "Reloaded!"

# TPM plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'

# Initialize TPM
run '~/.tmux/plugins/tpm/tpm'
TMUXCONF
fi

# Install TPM and plugins if needed
install_tpm
install_plugins

# Source updated config for any existing tmux server
if tmux list-sessions &>/dev/null; then
    echo "Updating tmux configuration..."
    tmux source-file "$TMUX_CONF" 2>/dev/null || true
fi

# Find an available session name
SESSION_NAME=$(find_available_session_name)

if [[ -z "$SESSION_NAME" ]]; then
    echo "Error: All phonetic alphabet session names are in use (alpha through zulu)."
    echo "Please close an existing tmux session and try again."
    exit 1
fi

# Create the tmux session with our config and start the selected agent
echo "Creating tmux session: $SESSION_NAME (agent: $AGENT)"
tmux -f "$TMUX_CONF" new-session -d -s "$SESSION_NAME" -c "$START_SH_WORKDIR"

# Protect the tmux server from the OOM killer: on memory exhaustion the kernel
# should kill a claude worker pane, not the server (killing the server takes
# down every session at once). See the 2026-05-25 OOM incident. Needs
# passwordless sudo for choom.
SERVER_PID=$(tmux -f "$TMUX_CONF" display-message -t "$SESSION_NAME" -p '#{pid}' 2>/dev/null)
if [[ -n "$SERVER_PID" ]]; then
    if sudo -n choom -n -1000 -p "$SERVER_PID" >/dev/null 2>&1; then
        echo "Protected tmux server $SERVER_PID from OOM killer (oom_score_adj=-1000)"
    else
        echo "Warning: could not set OOM protection on tmux server $SERVER_PID (needs passwordless sudo + choom)"
    fi
fi

# tmux needs one shell command rather than an argv. Quote every element so a
# session name containing whitespace or shell metacharacters remains exactly
# one inert resume argument when the pane's shell evaluates the command.
printf -v AGENT_COMMAND '%q ' "${AGENT_ARGV[@]}"
AGENT_COMMAND=${AGENT_COMMAND% }
tmux send-keys -t "$SESSION_NAME" "unset CLAUDECODE && exec $AGENT_COMMAND" Enter

# Attach to the session
echo "Attaching to session: $SESSION_NAME"
tmux -f "$TMUX_CONF" attach-session -t "$SESSION_NAME"
