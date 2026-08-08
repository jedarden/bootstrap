#!/bin/bash

# start.sh - Tmux + coding-agent launcher with self-update
#
# Launches an interactive coding agent - claude or codex. Outside herdr it
# creates a phonetic-alphabet tmux session and starts the agent inside it.
# Inside a herdr pane (herdr injects HERDR_ENV=1 into every pane it spawns) it
# skips tmux entirely and execs the agent in the current pane: herdr already
# provides the pane/tab layer, and a nested tmux session would burn a phonetic
# name and interfere with herdr's screen-manifest agent-status detection.
#
# This file is the single canonical copy. bootstrap.sh embeds a byte-for-byte
# copy of it in a heredoc (Step 13) so freshly-bootstrapped hosts get it on
# first run; every host's copy self-updates from this file afterward (see
# check_for_self_update below). Never hand-edit a deployed ~/start.sh on a
# host and never edit only one of the two copies in this repo - run
# ex44/sync-start-sh.sh after any change here to regenerate bootstrap.sh's
# embedded copy, then commit both together. See docs/plan/plan.md ADR-1 for
# why (a hand-patched host copy and a corrupted embedded copy both went
# undetected in the wild before this rule existed).
START_SH_VERSION="1.2.0"
REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44"

usage() {
    cat <<'USAGE'
Usage: start.sh [--agent claude|codex] [--no-update] [--version] [--help]

  --agent <name>   Coding agent to launch: claude (default) or codex.
                   Also settable via the START_SH_AGENT environment variable.
                   If neither is given and stdin is a TTY, start.sh prompts;
                   with no TTY it defaults to claude so that scripted or
                   piped invocations never block on the prompt.
  --no-update      Skip the start.sh self-update check.
  --version, -v    Print the start.sh version and exit.
  --help, -h       Show this help and exit.
USAGE
}

# Captured before parsing so a self-update re-exec can replay the user's
# original flags (notably --agent) instead of dropping them.
ORIGINAL_ARGS=("$@")

SKIP_UPDATE=false
AGENT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v)
            echo "start.sh v${START_SH_VERSION}"
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
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_DIR="$SCRIPT_DIR/.tmux"
TMUX_CONF="$TMUX_DIR/tmux.conf"
TPM_DIR="$TMUX_DIR/plugins/tpm"

# Self-update function
check_for_self_update() {
    if $SKIP_UPDATE; then
        return 0
    fi

    local remote_version
    remote_version=$(curl -sfL "$REPO_URL/start.sh.version" 2>/dev/null || echo "")

    if [[ -z "$remote_version" ]]; then
        return 0  # Can't check, continue anyway
    fi

    # Compare versions
    if [[ "$START_SH_VERSION" != "$remote_version" ]]; then
        local lowest
        lowest=$(printf '%s\n%s' "$START_SH_VERSION" "$remote_version" | sort -V | head -n1)
        if [[ "$START_SH_VERSION" == "$lowest" && "$START_SH_VERSION" != "$remote_version" ]]; then
            echo "Updating start.sh: $START_SH_VERSION -> $remote_version"
            local new_script
            new_script=$(curl -sfL "$REPO_URL/start.sh" 2>/dev/null)
            # Guard against installing a broken or empty payload (e.g. a
            # login page, truncated fetch, or corrupted commit) - verify it
            # parses as valid bash before overwriting the working script.
            if [[ -n "$new_script" ]] && bash -n <(printf '%s' "$new_script") 2>/dev/null; then
                echo "$new_script" > "$SCRIPT_DIR/start.sh"
                chmod +x "$SCRIPT_DIR/start.sh"
                echo "Updated! Restarting..."
                exec "$SCRIPT_DIR/start.sh" --no-update ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
            elif [[ -n "$new_script" ]]; then
                echo "Warning: fetched start.sh failed syntax check, keeping current version $START_SH_VERSION"
            fi
        fi
    fi
}

check_for_self_update

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
    case "$AGENT" in
        claude) check_and_update_claude ;;
        codex)  check_and_update_codex ;;
    esac
}

# Launch argv for the selected agent. Both run with their approval prompts
# disabled, matching what this launcher has always done for Claude Code -
# these are dedicated single-tenant boxes reached only over Tailscale.
set_agent_argv() {
    case "$AGENT" in
        claude)
            AGENT_ARGV=(claude --dangerously-skip-permissions --model sonnet)
            ;;
        codex)
            AGENT_ARGV=(codex --dangerously-bypass-approvals-and-sandbox)
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
tmux -f "$TMUX_CONF" new-session -d -s "$SESSION_NAME" -c "$SCRIPT_DIR"

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

# No element of AGENT_ARGV contains whitespace, so [*] is safe to splice into
# the send-keys command string.
tmux send-keys -t "$SESSION_NAME" "unset CLAUDECODE && exec ${AGENT_ARGV[*]}" Enter

# Attach to the session
echo "Attaching to session: $SESSION_NAME"
tmux -f "$TMUX_CONF" attach-session -t "$SESSION_NAME"
