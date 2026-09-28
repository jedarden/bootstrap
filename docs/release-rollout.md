# Recurring multi-host release rollout

This is the repeatable operator workflow for every launcher/bootstrap release.
It applies to every immediate host lineage under hosts/, including a lineage
that intentionally has host-specific keys or hardening. The directory name is
the release lineage; keep a separate, reviewed SSH target mapping for the
machines that consume it.

The release invariant is:

~~~text
Forgejo origin/main = GitHub main = GitHub raw artifacts = deployed host versions
~~~

Forgejo is the only write-side remote. Its configured server-side mirror
publishes GitHub and the raw HTTPS files used by the launcher. Do not add a
second client-side push remote.

## Prepare and validate every lineage

Record the target version and the last known-good commit before changing any
release files. A rollback is a new, higher version even when it restores an
older payload.

~~~bash
VERSION=1.3.2
KNOWN_GOOD_COMMIT=$(git rev-parse HEAD)
HOST_DIRS=$(find hosts -mindepth 1 -maxdepth 1 -type d -print | sort)
test -n "$HOST_DIRS"
~~~

Prepare the same release version independently for each lineage. The helper's
--check validates Bash syntax, the generated embedded launcher, the
standalone/embedded/bootstrap/archive/version-marker agreement, the signed
manifest and every artifact digest. Keep the signing private key outside the
repository and pass only its path through ARTIFACT_SIGNING_KEY.

~~~bash
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    ARTIFACT_SIGNING_KEY=/secure/path/bootstrap-artifacts-signing.pem ./scripts/start-sh-release.sh --host "$host" release "$VERSION"
    ./scripts/start-sh-release.sh --host "$host" --check
done
~~~

Run both parity views. --live checks the current worktree; --staged must be
run after staging and checks exactly the proposed Git index, so an unstaged
drift cannot hide behind a clean worktree check.

~~~bash
./scripts/check-host-parity.sh --live

# Stage only the exact release files for each changed host. Repeat this block
# for every host lineage; do not use git add . or git add -A.
git add hosts/ex44/start.sh hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version hosts/ex44/artifact-manifest.txt hosts/ex44/artifact-manifest.sig hosts/ex44/bootstrap-"$VERSION".sh
# Add the corresponding six paths under each additional hosts/<name>/.

./scripts/check-host-parity.sh --staged
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    ./scripts/start-sh-release.sh --host "$host" --check
done
git diff --cached --check
~~~

Review the staged diff, then commit on main. The release files must be
committed before either publishing or rolling out.

~~~bash
git diff --cached -- hosts/
git commit -m "release(start.sh): v$VERSION"
~~~

## Publish and prove distribution convergence

Run publish once for each lineage. The first invocation pushes origin/main;
subsequent invocations are harmless no-op pushes that verify the other
lineages. Each invocation confirms Forgejo main is the committed HEAD, waits
for GitHub main to converge, and byte-compares the GitHub raw bootstrap.sh,
start.sh, version marker, signed manifest, signing/public keys, and current
immutable archive with that commit.

~~~bash
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    ./scripts/start-sh-release.sh --host "$host" publish
done

# Keep this explicit audit in the release record even though publish runs it.
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    ./scripts/start-sh-release.sh --host "$host" distribution-check
done
test -z "$(git rev-list origin/main..HEAD)"
~~~

Do not roll out when a distribution check fails. A GitHub commit hash without
matching raw files is not a usable release; wait for the mirror or investigate
the mismatch.

## Roll out and verify every host

The target map is operator-owned and intentionally separate from the
repository's lineage directories. Review it before every rollout. The
following deterministic SSH operation installs the already-reviewed launcher
from the committed lineage, checks syntax before replacement, and prints the
deployed version. It is also a recovery path when a host's old self-update
cannot reach the new repository layout. A normal start invocation may
self-update instead, but verify it with the same --no-update --version check
after it completes.

~~~bash
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    case "$host" in
        ex44) target=coding@ex44.jedarden.com ;;
        lab) target=coding@lab.ardenone.com ;;
        *) echo "missing target for $host" >&2; exit 1 ;;
    esac
    ssh "$target" 'set -eu
        tmp=$(mktemp "$HOME/start.sh.XXXXXX")
        trap '\''rm -f "$tmp"'\'' EXIT
        cat > "$tmp"
        chmod 0755 "$tmp"
        bash -n "$tmp"
        mv -f "$tmp" "$HOME/start.sh"
        trap - EXIT
        bash -n "$HOME/start.sh"
        "$HOME/start.sh" --no-update --version
    ' < "$host_dir/start.sh" | grep -Fx "start v$VERSION"
done
~~~

Record the target and observed version for every host. Do not report the
rollout complete if one target is unavailable or reports a different version.
The local start.sh.version and signed manifest checks do not substitute for
this live inventory check.

## Roll back without moving backward

If the release is unhealthy, stop further rollout and use the recorded
KNOWN_GOOD_COMMIT. The rollback helper restores that payload but publishes it
under a new forward version, preserving the launcher's monotonic self-update
rule and the immutable archive history. Repeat the same staged, publish,
distribution, and every-host rollout gates for the rollback release.

~~~bash
ROLLBACK_VERSION=1.3.3
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    ARTIFACT_SIGNING_KEY=/secure/path/bootstrap-artifacts-signing.pem ./scripts/start-sh-release.sh --host "$host" rollback "$KNOWN_GOOD_COMMIT" "$ROLLBACK_VERSION"
done

./scripts/check-host-parity.sh --live
# Stage only each host's six rollback release paths, then:
./scripts/check-host-parity.sh --staged
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    ./scripts/start-sh-release.sh --host "$host" --check
done
git commit -m "rollback(start.sh): v$ROLLBACK_VERSION"
for host_dir in $HOST_DIRS; do
    host=$(basename "$host_dir")
    ./scripts/start-sh-release.sh --host "$host" publish
done
# Repeat the rollout/version-verification loop above with ROLLBACK_VERSION.
~~~

The immutable archive for the failed release remains tracked and verifiable;
never delete or rewrite it. The rollback is complete only after Forgejo,
GitHub/raw HTTPS, every host's deployed start.sh --version, and the final
signed/versioned artifact checks all agree on the rollback version.

## Offline regression test

The complete sequence is exercised without external hosts or network access by
the disposable two-lineage test:

~~~bash
tests/release-rollout-workflow-test.sh
~~~

It models Forgejo and its GitHub/raw mirror with local bare repositories,
checks both live and staged parity, validates signed version metadata, pushes
and audits both lineages, installs each launcher through a fake SSH target,
checks every deployed version, and repeats the full flow for a forward-version
rollback.
