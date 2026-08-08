# bootstrap — Plan

This file did not exist before 2026-07-20. It is being started honestly, not
backfilled retroactively: the sections below cover only what's known and
decided as of this pass. Add to "Overview" and "Open Questions" as the repo
evolves; add new `## ADR-N:` sections for future architectural decisions
(never edit a past ADR's Decision after the fact — supersede it with a new
one and link back).

## Overview

`bootstrap` provisions and hardens Hetzner EX44 dedicated servers running
Debian/Ubuntu: system hardening (SSH, UFW, sysctl, fail2ban, auditd), isolated
per-user workspaces, Tailscale mesh access, rootless Docker, restic+B2 backup,
and a self-updating `start.sh` launcher (tmux + Claude Code) dropped into each
user's home directory. It has no server-side component of its own — the
"deployed artifact" is the shell scripts themselves, running as root during
one-time bootstrap and then as an unprivileged per-user launcher (`start.sh`)
on every subsequent login. `ex44.jedarden.com` in this workspace's fleet (the
box this repo is checked out on, along with `lab.ardenone.com`) is a running
instance of what this repo produces.

Distribution model: Forgejo (`git.ardenone.com`) is the commit source of
truth per this workspace's hosting convention, mirrored to GitHub
(`github.com/jedarden/bootstrap`). Both `bootstrap.sh`'s one-time `curl | bash`
install instructions and every host's `start.sh` self-update mechanism
deliberately pull from the GitHub mirror (`raw.githubusercontent.com`), not
Forgejo directly — see ADR-1 for why that's intentional, not an oversight.

## Open Questions

- Should `ex44/` become `hosts/ex44/` (or similar) now that a second machine
  (`lab.ardenone.com`) exists in the same fleet running the same script? The
  README's "Future Plans" (Ansible playbooks, K8s-triggered provisioning) both
  assume more than one target eventually.
- Is `AllowTcpForwarding yes` (re-enabled in the SSH hardening step alongside
  `PermitRootLogin prohibit-password`, both loosened at some point after the
  original hardened defaults of `no`/`no`) an intentional tradeoff for some
  workflow, or drift that should be tightened back up? Worth a decision either
  way instead of silent divergence from the README's stated security posture.

## ADR-1: 2026-07-20 — Single canonical source for start.sh, with a hard syntax gate on self-update

### Context

`bootstrap.sh` embeds a full copy of `start.sh` in a heredoc (Step 13,
"Setting Up start.sh for Users") to drop it into each new user's home
directory on first bootstrap. `ex44/start.sh` is *also* checked into the repo
as a standalone file — this is the file every already-bootstrapped host's
`start.sh` self-updates from on each launch, via
`check_for_self_update()` pulling `$REPO_URL/start.sh.version` and
`$REPO_URL/start.sh` from the GitHub mirror.

These were two hand-maintained copies of the same content, kept in sync (in
theory) by whoever edited one remembering to paste the same change into the
other. Auditing the live, currently-running artifact against the repo
surfaced two ways that already failed silently:

1. **Content drift, undetected for ~8 weeks.** The copy of `start.sh`
   actually running on `ex44` (`~/start.sh`, i.e. what this very session
   launched from) carries a fix not present in either repo copy: after a
   2026-05-25 incident where the tmux server itself was OOM-killed —
   terminating every live NATO-named session simultaneously instead of just
   one pane — someone hand-patched `~/start.sh` on the box to set
   `oom_score_adj=-1000` on the tmux server PID via `choom`, and separately
   lowered `history-limit` from 10000 to 2000 and pinned `--model sonnet` on
   the launched `claude` process. None of this reached the repo. Worse: the
   live patch *deleted* the self-update block entirely (`START_SH_VERSION`
   and `check_for_self_update` are simply gone from the running file),
   meaning ex44 can never again pull a repo fix automatically, even now.
   `lab.ardenone.com`'s copy has neither the self-update block removed nor
   the OOM fix — it still matches the repo's stale pre-fix content, and
   remains exposed to the exact same failure mode that already happened once
   on ex44.
2. **The standalone `ex44/start.sh` in the repo was not valid bash.** It
   began with `for user in "${USERS[@]}"; do ... cat > "/home/$user/start.sh"
   << 'STARTSH'` — a fragment leaked in from a bad copy-paste out of
   `bootstrap.sh`'s Step 13 — and the heredoc it opened was never closed.
   `bash -n ex44/start.sh` failed outright: *"here-document at line 3
   delimited by end-of-file (wanted `STARTSH'), syntax error: unexpected end
   of file."* This exact broken file is what `raw.githubusercontent.com`
   serves today as `$REPO_URL/start.sh`. Self-update hasn't triggered only
   because `start.sh.version` still reads `1.1.2`, matching what every host
   already has. The moment that version file is bumped — which is required
   to ship *any* future `start.sh` fix, including the OOM one above — every
   host whose self-update block is still intact (i.e. every host except
   ex44, which lost it in the hand-patch) would `curl` down this syntax-error
   file, overwrite its own working launcher, and `exec` straight into a
   crash. Shipping the OOM fix through the old process would have bricked
   the launcher fleet-wide at the same moment it fixed the OOM bug.

### Decision

Treat `ex44/start.sh` as the single canonical, independently-runnable source.
`bootstrap.sh`'s embedded copy is now *generated* from it by
`ex44/sync-start-sh.sh` (byte-for-byte substitution between the heredoc
markers, with a `bash -n` check on both files before and after) instead of
hand-edited — the script fails loudly on drift instead of trusting memory.
Both copies are committed together in this same change, along with the
concrete fixes: the corrupted heredoc leak is removed, the OOM-protection
`choom` block / `history-limit 2000` / `--model sonnet` are backported from
the live ex44 host into the canonical file (keeping the *more* robust
dual-location Claude-Code-path check that was already in the repo, which the
live hand-patch had regressed to a single location), and
`check_for_self_update()` now runs `bash -n` on the fetched payload before
installing it — so a corrupted, truncated, or (see below) HTML-login-page
response can never again silently become the next `start.sh`.

Self-update keeps pulling from the GitHub mirror (`raw.githubusercontent.com`),
not Forgejo. This was checked, not assumed: an unauthenticated `curl` against
`git.ardenone.com/jedarden/bootstrap/raw/branch/main/ex44/start.sh.version`
returns **HTTP 200** with a Forgejo sign-in page's HTML — this instance
requires authentication for all access, even to public repos, and `curl -f`
only trips on 4xx/5xx, so it would treat that login page as a successful
fetch. `check_for_self_update`'s new `bash -n` payload check catches this
case too (the HTML fails to parse as bash), but the deliberate choice is:
GitHub stays the read side for this artifact's live self-update path, Forgejo
stays the write side (source of truth for history/commits), same as this
workspace's existing hosting split — just made explicit here in code and in
this doc so a future "fix" doesn't point self-update at Forgejo and
reintroduce the login-page bug.

### Alternatives Considered

1. **Keep hand-syncing, just be more careful.** Rejected — this is the
   exact discipline that already produced both failures above; there's no
   reason to expect it holds going forward when it didn't hold for the last
   several versions.
2. **Point self-update at Forgejo directly**, consistent with "Forgejo is
   the source of truth" elsewhere in this workspace. Rejected on evidence:
   this Forgejo instance gates all access (API and raw file content) behind
   sign-in, even for public repos. An unauthenticated fetch doesn't fail, it
   silently returns a login page as HTTP 200 — the most dangerous failure
   mode for a script that installs whatever it fetches.
3. **Drop self-update entirely; require re-running `bootstrap.sh` per host
   for any launcher change.** Rejected as the primary fix — it doesn't
   address the root cause (two copies, one hand-generated from the other)
   and loses the "hosts pick up small fixes on next launch" property, which
   is valuable for a two-machine, always-on fleet. Worth reconsidering
   later if the fleet grows enough to justify the README's already-stated
   "Ansible playbooks for drift management" future plan — that would replace
   this whole mechanism, not patch it.
4. **Chosen:** single canonical file, generated embedded copy with a sync
   script that refuses to produce a syntactically-broken result, a runtime
   syntax gate on the self-update payload itself, and immediate backport of
   the two fixes already proven-good in production.

### Consequences

- Any future `start.sh` change ships by editing `ex44/start.sh`, running
  `ex44/sync-start-sh.sh`, and committing both files — there is exactly one
  place to make the change, and the sync script's `bash -n` gates make a
  repeat of either failure mode (corrupted embedded copy, or a
  syntactically-invalid self-update payload reaching a host) fail the sync
  step or the update step instead of failing silently in production.
- `lab.ardenone.com` gets OOM protection the next time its `start.sh` runs
  and self-updates (or is manually re-run) — it does not require a fresh
  bootstrap.
- This pass does **not** modify the live files on `ex44` or `lab` directly
  (out of scope for a repo-only audit) — the fix reaches them only via the
  normal self-update path the next time a human or agent launches a session
  there. `ex44`'s live `~/start.sh` in particular has no self-update block
  left to trigger on its own; someone needs to either re-run `~/start.sh`
  once manually after fetching the new version, or replace it by hand one
  more time (ideally the last time) with the now-canonical repo copy.
- Added maintenance cost: `ex44/sync-start-sh.sh` must actually be run (it's
  not wired into a commit hook or CI yet — this repo has no CI). A follow-up
  bead should add a pre-commit check or Argo Workflow that runs it in
  `--check` mode and fails the build if `bootstrap.sh`'s embedded copy and
  `ex44/start.sh` disagree, closing the last gap (someone still forgetting to
  run the script).

## ADR-2: 2026-08-07 — start.sh selects a coding agent (claude|codex) and defers to herdr

### Context

`start.sh` hard-coded a single launch path: create a phonetic-alphabet tmux
session, then `send-keys` a fixed
`unset CLAUDECODE && exec claude --dangerously-skip-permissions --model sonnet`.
Two things have changed underneath that assumption.

First, Claude Code is no longer the only interactive agent in use on these
hosts — the Codex CLI (`@openai/codex`, an npm global) is installed on `ex44`
and there was no way to launch it through the standard launcher.

Second, herdr (`herdr.dev`, a terminal multiplexer purpose-built for running
several agent CLIs side by side) now runs on `ex44` and rides on the *same*
ambient tmux server as the phonetic sessions. Running `start.sh` from inside a
herdr pane therefore nested a tmux session inside a pane that was already a
multiplexed view: it consumed a phonetic name for a session nobody would
attach to by name, and the extra tmux status chrome interferes with herdr's
screen-manifest agent-status detection (herdr pattern-matches an agent's
bottom-buffer to infer idle/working/blocked; Claude Code and Codex are both on
that fallback tier rather than hook-reported state, so the buffer's contents
matter).

A prior memory note asserted `start.sh` already handled the herdr case. It did
not — neither the repo copy, the deployed `~/start.sh`, nor the published
`raw.githubusercontent.com` copy contained the string `herdr` at any point
before this ADR. The belief was wrong, not the implementation.

### Decision

`start.sh` v1.2.0 selects an agent and picks a launch strategy.

**Agent selection**, in precedence order: `--agent claude|codex` >
`$START_SH_AGENT` > interactive prompt > `claude`. The prompt is gated on
`[[ -t 0 ]]`; with no TTY the launcher announces the fallback and takes
`claude`. An invalid value from either the flag or the environment variable is
a hard error rather than a silent coercion to the default.

The TTY gate is the load-bearing part: `start.sh` is a login-time launcher and
is also embedded verbatim into `bootstrap.sh`, so an unconditional `read`
would be a latent hang in any non-interactive invocation. Selection happens
before the installer step so that choosing `codex` never triggers a Claude
Code install (and vice versa).

**Launch strategy** branches on `HERDR_ENV`, which herdr injects into every
pane it spawns. Inside a herdr pane, `start.sh` skips tmux, TPM, and the
`choom` OOM-protection step entirely and `exec`s the agent in the current
pane. Outside herdr, behavior is unchanged from v1.1.3 except that the
`send-keys` command string is now built from the selected agent's argv.

Codex gets an install/update path mirroring Claude Code's, but through npm
(`npm view @openai/codex version` to check, `npm install -g @openai/codex@latest`
to install). Unlike the Claude path, a *failed upgrade* when a working copy is
already present is a warning rather than a fatal error.

### Alternatives Considered

- **Prompt only inside herdr, leave the tmux path claude-only.** Smaller
  change and matches how the need surfaced, but leaves two different launcher
  behaviors depending on where you happen to be sitting. Rejected in favor of
  one consistent selection model.
- **Interactive prompt with no flag or environment override.** Simpler, but
  unscriptable and reintroduces the non-interactive hang risk that the TTY
  gate exists to prevent.
- **Detect herdr via `HERDR_SOCKET_PATH` or by walking `/proc` for a herdr
  server.** `HERDR_ENV=1` is the documented, cheapest, and most direct signal;
  the others are proxies for it.
- **`codex update` for the upgrade path.** It exists as a subcommand, but its
  interactivity is unverified and an updater that can prompt is exactly the
  kind of thing that hangs a launcher. npm is already how Codex is installed
  on these hosts.

### Consequences

- Hosts pick this up through the normal self-update path (v1.1.3 → v1.2.0) the
  next time `start.sh` runs. No re-bootstrap needed.
- The self-update re-exec now replays the user's original argv
  (`ORIGINAL_ARGS`) instead of the previous `"$@"`-inside-a-function, which
  silently dropped flags. `--agent codex` survives an update-and-restart.
- Argument parsing moved from two `$1` string comparisons to a real `while`
  loop, so flags now work in any order and an unknown flag is a usage error
  rather than being ignored. Anything that previously passed junk arguments
  and got away with it will now fail loudly.
- Both agents still launch with approval prompts disabled
  (`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`).
  That matches the launcher's long-standing behavior and these hosts' posture
  (dedicated, single-tenant, reachable only over Tailscale); it is not a new
  exposure, but it is now a decision made twice rather than once.
- Codex support adds an npm dependency to one branch of the launcher. On a
  host without npm, choosing `codex` fails with an actionable message; the
  `claude` branch is unaffected.
