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

- None open. (The 2026-07-20 question about `AllowTcpForwarding yes` /
  `PermitRootLogin prohibit-password` being drift vs. tradeoff was resolved
  by ADR-6 — they are intentional; see there for the git-history evidence.)

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

## ADR-3: 2026-08-08 — Generalize the nesting guard from herdr to any multiplexer

### Context

ADR-2 added a `HERDR_ENV` branch so `start.sh` would not create a tmux session
inside a herdr pane. Reviewing that change surfaced the same bug one level
down, and it predates ADR-2 entirely: `start.sh` has never checked `$TMUX`.

Run from inside an existing tmux client, the launcher would run the whole tmux
path to completion — allocate a phonetic name, create the session, `choom` it,
`send-keys` the agent — and only fail at the very last step, `attach-session`,
which tmux refuses from inside another client. The failure is maximally
unhelpful: it happens after all the side effects, so it leaves a detached
session running a live agent that nobody is attached to, holding a phonetic
name. Nothing cleans that up, and the next `start.sh` run picks the next
letter, so the leak accumulates silently.

### Decision

Guard on `$TMUX` with the same strategy as the herdr branch: announce the
reason, then `exec` the selected agent in the current pane.

The `$TMUX` check is placed **after** the `HERDR_ENV` check, not before.
herdr rides on the same ambient tmux server as the phonetic sessions, so a
herdr pane has both variables set; ordering herdr first means such a pane
reports the more specific reason ("Detected herdr pane w3:p7") rather than the
generic tmux one. Both branches take identical action, so the ordering only
affects the message — but the message is the whole diagnostic value.

The current session name is read via `tmux display-message -p '#S'` purely for
the log line, and degrades to "unknown" if that fails.

### Alternatives Considered

- **Create the session detached and `switch-client` to it.** This is the other
  correct way to handle tmux-inside-tmux, and it preserves the phonetic-session
  model that the NATO fleet convention depends on. Rejected for now because it
  is a different feature (a second launch mode) rather than a guard, and
  because the behavior it would preserve is one nobody currently has — the path
  has always been broken. Worth revisiting if spawning a new named session from
  inside tmux turns out to be a real workflow.
- **Hard error and exit non-zero.** Safe and obvious, but strictly worse than
  doing the useful thing: the user asked for an agent, and there is an
  unambiguous correct place to put one.
- **`unset TMUX` and force the nested attach.** Actually nests a client inside
  a client. This is the thing the guard exists to prevent.

### Consequences

- Running `start.sh` inside tmux now launches the agent in the current pane
  instead of leaking a detached session. The detached-session leak is fixed at
  the source; any sessions already leaked by earlier versions are still around
  and need manual cleanup (they are ordinary tmux sessions holding phonetic
  names).
- The tmux path proper is now reached only from a bare shell. In particular
  the "source the updated config into a running tmux server" step no longer
  runs when invoked from inside tmux — acceptable, since that invocation no
  longer creates a session, and `prefix + r` still reloads config by hand.
- All three launch contexts (herdr pane, tmux client, bare shell) are now
  explicit and tested, rather than two explicit ones and an unhandled case.

## ADR-4: 2026-08-23 — Sync enforcement moved from discipline to a pre-commit hook

### Context

ADR-1 left running the sync script as a manual step ("must actually be run —
it's not wired into a commit hook or CI yet"). The gap admitted real
failures: a `# TEST` debug line landed in `bootstrap.sh`'s embedded copy
with no matching change to the standalone `start.sh` (introduced across the
2026-08 IPv6-hardening series, unnoticed on main until the hook's first
run), which is the same hand-discipline failure mode ADR-1 was written
after. This repo has no CI — GitHub Actions are disabled org-wide and no
Argo Workflow is wired up for it — so nothing stood between a forgotten
sync run and the repo.

### Decision

Enforce at commit time with a versioned pre-commit hook:
`githooks/pre-commit`, activated per clone with
`git config core.hooksPath githooks` (git does not version hooks itself).

The hook checks the **index**, not the working tree. It materializes the
staged `start.sh`, `bootstrap.sh`, and `sync-start-sh.sh` into a temp
directory and runs `sync-start-sh.sh --check` there — validating exactly
what is being committed, never writing to the working tree from inside a
hook, and tolerating both the `ex44/` and `hosts/ex44/` layouts (discovered
from the index, `hosts/` first, so it survives the multi-host restructure
without changes). `--check` diffs without writing and exits nonzero on
mismatch; the hook turns that into a blocked commit with the fix spelled
out.

### Alternatives Considered

- **Argo Workflow CI check.** Deferred, not rejected — no workflow is wired
  up for this repo, and a hook catches the mistake at the moment of commit
  rather than after push. CI becomes worth it if contributors routinely
  bypass hooks.
- **Installing into `.git/hooks/pre-commit` directly.** Not versioned; lost
  on every fresh clone and invisible in review. The versioned `githooks/`
  dir plus one documented config command per clone keeps the hook in the
  repo's history.

### Consequences

- The `# TEST` drift is reverted in the same commit that introduces the
  hook, so the pair the hook first guards is in sync — the hook never
  blocks unrelated commits over pre-existing drift.
- Unstaged working-tree edits cannot block an unrelated commit, and a stale
  working tree cannot smuggle a bad pair past the check; only the staged
  pair matters.
- Enforcement is per-clone opt-in until CI exists: a checkout that skips
  `git config core.hooksPath githooks` gets no enforcement. The README
  documents the one-liner.

## ADR-5: 2026-08-23 — Multi-host layout: one directory per fleet host under `hosts/`

### Context

`lab.ardenone.com` has run the same bootstrap script and `start.sh` as
`ex44.jedarden.com` since the fleet gained its second machine, and the
README's stated future plans (Ansible drift management, K8s-triggered
provisioning) both assume more than one target host. The repo, however, was
still laid out as a single-host repo: everything lived under `ex44/`.

The restructure had also already half-happened, without a decision behind
it: commit 385918b (2026-08-15) created `hosts/ex44/bootstrap.sh` and
`hosts/ex44/README.md` as a parallel copy while `ex44/` stayed in place,
leaving **two tracked lineages of `bootstrap.sh` diverging in one repo**.
The `hosts/` copy was the more evolved one (it carried the `--verify` mode,
the OpenBao Tailscale-guard fix, the `traefil`→`traefik` hostname fix, and
`REPO_URL`/quickstart URLs already pointing at `hosts/ex44`), but nothing
recorded which copy was canonical — the exact ambiguity this ADR closes.

### Decision

Adopt `hosts/<hostname>/` as the layout:

- `ex44/` → `hosts/ex44/`. The merge keeps the evolved Aug-15
  `hosts/ex44/` `bootstrap.sh` and `README.md`, and moves everything else —
  `start.sh`, `start.sh.version`, `sync-start-sh.sh`, `keys/`, and the
  versioned `bootstrap-<version>.sh` archives — from `ex44/` unchanged.
  `ex44/` ceases to exist; there is exactly one canonical script again.
- **One shared script serves the whole fleet.** `hosts/lab/` is created only
  when lab needs host-specific content (different keys, backup targets, or
  hardening), by copying the then-current `hosts/ex44/` script and diverging
  from there; per-host keys and archives then live under that host's
  directory. New hosts get `hosts/<name>/` at bootstrap time.
- `start.sh` v1.2.2 moves its `REPO_URL` to
  `.../bootstrap/main/hosts/ex44` (version bumped per the standing edit
  procedure — `REPO_URL` is behavior, not comment).

### Alternatives Considered

- **`shared/` plus per-host thin overlays.** Rejected: the script is
  consumed as one self-contained file over a raw HTTPS URL (`curl | bash`,
  fleet self-update, key fetch); overlays would fragment that path and add
  indirection to serve divergence that does not exist yet.
- **Do nothing until lab actually diverges.** Rejected: the two-lineage
  state already existed in git and actively misleads (two `bootstrap.sh`
  copies, one answering to the name the docs use); the raw URLs and the
  self-update path also need one stable home regardless of divergence.
- **Top-level per-host dirs (`ex44/`, `lab/`).** Rejected: a `hosts/`
  namespace keeps fleet targets distinguishable from `docs/`, `githooks/`,
  etc. as the repo grows, at the cost of one path component.

### Consequences

- Every raw URL moves (quickstart lines, `REPO_URL`, the key fetch). Old
  `.../bootstrap/main/ex44/*` URLs 404 once this lands on the GitHub mirror.
- Deployed launchers self-update from the `REPO_URL` baked into each copy,
  so a host still holding a pre-1.2.2 launcher gets a 404 on
  `start.sh.version` after the move. `check_for_self_update` treats that as
  "can't check" and continues (`curl -sf` failure → empty remote version →
  skip), so nothing bricks — but such a copy never self-updates again until
  it is manually refreshed from `hosts/ex44/start.sh`. ex44's `~/start.sh`
  was refreshed to the canonical v1.2.2 as part of this change;
  `lab.ardenone.com` still needs its one-time manual refresh.
- The pre-commit hook (ADR-4) already discovers `hosts/ex44` from the index
  first and survives the move unchanged.
- Path references in ADR-1..4 written as `ex44/...` now resolve under
  `hosts/ex44/...`; per this doc's own rule the earlier ADRs are left as
  written.
- `git log --follow` tracks the untouched files across the move; the two
  files that already had a `hosts/ex44/` lineage (`bootstrap.sh`,
  `README.md`) carry their history from 385918b instead.

## ADR-6: 2026-08-23 — SSH posture: `prohibit-password` root and TCP forwarding are intentional, not drift

### Context

The original Step 7 hardened defaults (`/etc/ssh/sshd_config.d/hardening.conf`)
were `PermitRootLogin no`, `AllowTcpForwarding no`, and an `AllowUsers` list
without root. Commit 0b826f5 ("Update bootstrap.sh to v1.1.4", 2026-04-03)
loosened all three in one deliberate change whose message names the reasons:
"AllowTcpForwarding yes (fixes VS Code cloudflared connections)",
"PermitRootLogin prohibit-password (re-enables root SSH via key)", and
"Add root to AllowUsers". The README was *not* updated at the time, and its
Security Features section still said "No root login" — the silent doc/config
divergence this plan recorded as its first Open Question (2026-07-20) and
that bead `bootstra-349e7feb` asked to resolve.

The divergence turned out to be an artifact of the two-lineage split
described in ADR-5: the corrected documentation shipped with the
`hosts/ex44/` lineage from its creation (385918b, 2026-08-15) — a Security
Features section reading "Key-based root login allowed (Hetzner rescue
network emergency access)" and "TCP forwarding enabled (VS Code Remote SSH
support)", plus an inline comment on each of the three settings in the Step 7
heredoc — while the stale pre-drift prose lived on in the old
`ex44/README.md` until ADR-5 deleted that lineage on 2026-08-23.

### Decision

Keep the current posture; do not tighten back. Each setting is an
intentional tradeoff:

- **`PermitRootLogin prohibit-password` + `root` in `AllowUsers`** — the
  emergency-access path. UFW admits port 22 only from the Hetzner
  rescue-network ranges (FSN + NBG) and the `tailscale0` interface, and the
  README's Recovery section documents reaching the box via public IP from
  Hetzner Robot when Tailscale is down — that path needs root SSH permitted.
  Root remains key-only (`PasswordAuthentication no`,
  `AuthenticationMethods publickey`), so the added exposure is "anyone
  holding the operator's SSH key can reach root", which the key
  distribution already assumes.
- **`AllowTcpForwarding yes`** — VS Code Remote SSH (and the optional
  cloudflared tunnel, Step 11) needs port forwarding through the SSH
  connection; `no` broke that workflow in practice, which is why v1.1.4
  re-enabled it as a fix. `AllowAgentForwarding no` and `PermitTunnel no`
  are retained, so forwarding cannot be used to pivot agent credentials or
  layer-2 tunnels.

The documentation side is already in place in the canonical files:
`hosts/ex44/README.md`'s Security Features describes this posture, and the
Step 7 heredoc comments name each rationale. This ADR adds the missing
piece — the decision record tying them to the git-history evidence.
Verified 2026-08-23 that the live host (`hetzner-ex44`) runs exactly this
config: `permit-password` root, `AllowUsers root coding trading`, forwarding
on, password auth off.

### Alternatives Considered

- **Tighten back to `no`/`no`/no-root** to match the original hardened
  defaults. Rejected: it breaks the VS Code Remote SSH workflow and closes
  the only documented access path when Tailscale is down. The marginal
  hardening (key-only root *doesn't* exist; forwarding *can't* be used)
  protects against an attacker who already holds the operator's SSH key or
  a session on the box — not a meaningfully different threat for a
  single-operator dedicated server reachable only over Tailscale plus
  Hetzner's own rescue ranges.
- **Keep the settings, leave the README describing the stricter posture.**
  Rejected — that is the silent divergence that prompted the question in
  the first place.

### Consequences

- The 2026-07-20 Open Question is resolved (removed from the list above).
- A future change to any of these three settings must update, in the same
  commit: the `hosts/ex44/README.md` Security Features bullets, the Step 7
  heredoc comments, and (per this doc's rules) a superseding ADR linked
  back to this one.
- New fleet hosts (`hosts/<name>/`) inherit this posture by copying
  `hosts/ex44/`, so it is the fleet baseline, not an ex44-only exception.

## ADR-7: 2026-09-26 — Expose start.sh as a `start` command via symlink, not by moving the file

### Context

The launcher was run as `./start.sh --agent codex`, a script sitting in the
home directory. The wanted interface is a command on `PATH`: `start claude`,
`start codex`.

Two facts constrain how to get there. Every already-bootstrapped host
self-updates from `$REPO_URL/start.sh` and writes the result to
`$SCRIPT_DIR/start.sh`, so the deployed path is load-bearing for the whole
fleet. And `sync-start-sh.sh` locates the embedded copy by the heredoc line
`cat > "/home/$user/start.sh"`, so moving the deployed file also means
changing that marker in the same commit as everything else.

### Decision

`~/start.sh` stays the single deployed, self-updating file. `~/.local/bin/start`
is a **symlink** to it (v1.3.0). The script now resolves its real path with
`readlink -f`, so `SCRIPT_DIR` (and with it the tmux config directory, the
session working directory and the self-update target) is the same whether it is
launched as `~/start.sh` or through the link. Without that, launching via the
link would silently relocate `.tmux/` to `~/.local/bin/`.

The agent is also accepted positionally (`start codex`). `--agent` and
`START_SH_AGENT` keep working; a positional agent that disagrees with `--agent`
is an error rather than a silent precedence rule.

Link creation happens in two places: Step 13 of `bootstrap.sh` (as the user,
via `su -`, so `~/.local` is never root-owned), and `ensure_start_command` in
the script itself for hosts that predate it. The latter is deliberately narrow:
it acts only when the real path is `$HOME/start.sh`, and never replaces an
existing `start`.

### Alternatives rejected

- **Move the real file to `~/.local/bin/start`, leave `~/start.sh` as a
  compatibility symlink.** Cleaner end state, but it changes the path every
  deployed host self-updates into, forces a per-host migration step inside the
  script, and requires changing the sync script's heredoc marker in lockstep.
  Risk for no change in the interface the user sees.
- **Auto-link from any location.** A run from a repo checkout would point
  `start` at a tracked file, and the next self-update would write the fetched
  script through the link into the working tree.
- **A compiled binary.** The launcher is a thin `exec` wrapper around tools
  that are themselves on `PATH`; nothing in it needs compiling.

### Consequences

- Hosts converge without operator action: self-update lands v1.3.0, and the
  first run afterwards creates the link and prints one line saying so.
- `~/start.sh` remains in the home directory. If the file ever moves, the
  self-update path, the sync marker and this ADR change together.
- Sandbox-tested: fresh link, re-run, pre-existing unrelated `start`, launch
  through the link, non-deployed copy (no link), self-update through the link,
  and a real v1.2.2 to v1.3.0 upgrade.
