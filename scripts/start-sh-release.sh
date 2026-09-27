#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare, validate, and publish a hosts/ex44/start.sh release.
#
# The standalone start.sh is the source of truth. bootstrap.sh contains a
# generated copy, and start.sh.version is the version advertised to deployed
# launchers. Keep all three in agreement before committing or publishing.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOST_DIR="$ROOT/hosts/ex44"
START_SH="$HOST_DIR/start.sh"
BOOTSTRAP_SH="$HOST_DIR/bootstrap.sh"
VERSION_FILE="$HOST_DIR/start.sh.version"
SYNC_SH="$HOST_DIR/sync-start-sh.sh"
START_REL="hosts/ex44/start.sh"
FORGEJO_REMOTE="${FORGEJO_REMOTE:-origin}"
GITHUB_REPO_URL="${GITHUB_REPO_URL:-https://github.com/jedarden/bootstrap.git}"
GITHUB_RAW_ROOT="${GITHUB_RAW_ROOT:-https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44}"
DISTRIBUTION_TIMEOUT_SECONDS="${DISTRIBUTION_TIMEOUT_SECONDS:-120}"
DISTRIBUTION_POLL_SECONDS="${DISTRIBUTION_POLL_SECONDS:-2}"
DISTRIBUTION_TMP=

readonly DISTRIBUTION_ARTIFACTS=(
    'hosts/ex44/bootstrap.sh|bootstrap.sh'
    'hosts/ex44/start.sh|start.sh'
    'hosts/ex44/start.sh.version|start.sh.version'
)

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  scripts/start-sh-release.sh release VERSION
  scripts/start-sh-release.sh rollback GIT-REF VERSION
  scripts/start-sh-release.sh --check
  scripts/start-sh-release.sh distribution-check
  scripts/start-sh-release.sh publish

Commands:
  release VERSION       Set the next start.sh version, regenerate the
                        bootstrap.sh heredoc, and run all release checks.
  rollback GIT-REF VERSION
                        Restore start.sh from GIT-REF, publish it under a new
                        forward version, regenerate bootstrap.sh, and check it.
  --check               Verify syntax, generated-copy equality, and that the
                        standalone, embedded, and advertised versions agree.
  distribution-check    Verify Forgejo main is mirrored to GitHub and that
                        GitHub raw release artifacts match that commit.
  publish               Push the already-committed release to origin/main.
                        Then verify the Forgejo-to-GitHub distribution path;
                        this command does not push a second remote.

VERSION must be MAJOR.MINOR.PATCH and must be greater than the current
standalone version. A rollback therefore uses a new version even when its
payload came from an older Git commit; deployed launchers only move forward.
USAGE
}

require_version() {
    local version=${1:-}
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "invalid version '$version' (expected MAJOR.MINOR.PATCH)"
}

extract_start_version() {
    local path=$1
    local line
    mapfile -t lines < <(grep -E '^START_SH_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$path" || true)
    [[ ${#lines[@]} -eq 1 ]] ||
        die "$path must contain exactly one START_SH_VERSION assignment"
    line=${lines[0]#START_SH_VERSION=\"}
    printf '%s\n' "${line%\"}"
}

read_advertised_version() {
    local line
    mapfile -t lines < "$VERSION_FILE"
    [[ ${#lines[@]} -eq 1 ]] ||
        die "$VERSION_FILE must contain exactly one version line"
    line=${lines[0]%$'\r'}
    require_version "$line"
    printf '%s\n' "$line"
}

version_lt() {
    local left=$1 right=$2 lowest
    [[ "$left" != "$right" ]] || return 1
    lowest=$(printf '%s\n%s\n' "$left" "$right" | sort -V | head -n1)
    [[ "$left" == "$lowest" ]]
}

require_forward_version() {
    local current=$1 next=$2
    require_version "$next"
    version_lt "$current" "$next" ||
        die "version $next must be greater than current version $current"
}

check_versions() {
    local standalone embedded advertised
    standalone=$(extract_start_version "$START_SH")
    embedded=$(extract_start_version "$BOOTSTRAP_SH")
    advertised=$(read_advertised_version)

    [[ "$standalone" == "$embedded" ]] ||
        die "embedded version $embedded disagrees with standalone version $standalone"
    [[ "$standalone" == "$advertised" ]] ||
        die "advertised version $advertised disagrees with standalone version $standalone"

    echo "Version agreement: start.sh=$standalone, bootstrap.sh=$embedded, start.sh.version=$advertised"
}

check_release() {
    bash -n "$START_SH"
    bash -n "$BOOTSTRAP_SH"
    "$SYNC_SH" --check
    check_versions
}

remote_main_commit() {
    local remote=$1 output commit
    output=$(git -C "$ROOT" ls-remote "$remote" refs/heads/main 2>/dev/null) || return 1
    commit=$(awk '$2 == "refs/heads/main" { print $1; exit }' <<<"$output")
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s\n' "$commit"
}

cleanup_distribution_tmp() {
    if [[ -n "${DISTRIBUTION_TMP:-}" ]]; then
        rm -rf "$DISTRIBUTION_TMP"
        DISTRIBUTION_TMP=
    fi
}

fail_distribution() {
    cleanup_distribution_tmp
    die "$@"
}

raw_artifacts_match() {
    local tmp=$1 spec filename
    for spec in "${DISTRIBUTION_ARTIFACTS[@]}"; do
        filename=${spec#*|}
        curl --fail --location --silent --show-error \
            "$GITHUB_RAW_ROOT/$filename" > "$tmp/actual-$filename" 2>/dev/null || return 1
        cmp -s "$tmp/expected-$filename" "$tmp/actual-$filename" || return 1
    done
}

verify_distribution() {
    local expected_commit forgejo_commit github_commit expected_version
    local timeout poll deadline spec path filename

    check_release
    git -C "$ROOT" diff-index --quiet HEAD -- \
        hosts/ex44/bootstrap.sh hosts/ex44/start.sh hosts/ex44/start.sh.version ||
        die "release files have uncommitted changes; commit them before distribution-check"

    expected_commit=$(git -C "$ROOT" rev-parse HEAD) ||
        die "could not determine the expected release commit"
    forgejo_commit=$(remote_main_commit "$FORGEJO_REMOTE") ||
        die "could not resolve refs/heads/main from Forgejo remote '$FORGEJO_REMOTE'"
    [[ "$forgejo_commit" == "$expected_commit" ]] ||
        die "Forgejo main is $forgejo_commit, but expected committed release is $expected_commit"

    [[ "$DISTRIBUTION_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] ||
        die "DISTRIBUTION_TIMEOUT_SECONDS must be a non-negative integer"
    [[ "$DISTRIBUTION_POLL_SECONDS" =~ ^[0-9]+$ ]] ||
        die "DISTRIBUTION_POLL_SECONDS must be a non-negative integer"

    DISTRIBUTION_TMP=$(mktemp -d "${TMPDIR:-/tmp}/start-sh-distribution.XXXXXX")
    for spec in "${DISTRIBUTION_ARTIFACTS[@]}"; do
        path=${spec%%|*}
        filename=${spec#*|}
        if ! git -C "$ROOT" show "$expected_commit:$path" > "$DISTRIBUTION_TMP/expected-$filename"; then
            fail_distribution "expected release commit $expected_commit does not contain $path"
        fi
    done
    expected_version=$(tr -d '\r\n' < "$DISTRIBUTION_TMP/expected-start.sh.version")
    require_version "$expected_version"

    timeout=$DISTRIBUTION_TIMEOUT_SECONDS
    poll=$DISTRIBUTION_POLL_SECONDS
    deadline=$((SECONDS + timeout))
    while :; do
        if github_commit=$(remote_main_commit "$GITHUB_REPO_URL"); then
            if [[ "$github_commit" == "$forgejo_commit" ]] && raw_artifacts_match "$DISTRIBUTION_TMP"; then
                cleanup_distribution_tmp
                echo "Distribution verified: commit=$expected_commit, version=$expected_version"
                return 0
            fi
        else
            github_commit="unavailable"
        fi

        if (( SECONDS >= deadline )); then
            if [[ "$github_commit" != "$forgejo_commit" ]]; then
                fail_distribution "GitHub main is ${github_commit:-unavailable}, expected Forgejo commit $forgejo_commit"
            fi
            fail_distribution "GitHub raw release artifacts do not match commit $forgejo_commit"
        fi
        if (( poll > 0 )); then
            sleep "$poll"
        fi
    done
}

write_start_version() {
    local path=$1 version=$2 tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/start-sh-release.XXXXXX")
    sed -E "s/^START_SH_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"$/START_SH_VERSION=\"$version\"/" \
        "$path" > "$tmp"
    if ! cmp -s "$path" "$tmp" && ! grep -q "^START_SH_VERSION=\"$version\"$" "$tmp"; then
        rm -f "$tmp"
        die "could not update START_SH_VERSION in $path"
    fi
    chmod --reference="$path" "$tmp"
    mv "$tmp" "$path"
}

write_version_file() {
    printf '%s\n' "$1" > "$VERSION_FILE"
}

prepare_release() {
    local next=$1 current
    require_version "$next"
    bash -n "$START_SH"
    current=$(extract_start_version "$START_SH")
    require_forward_version "$current" "$next"

    write_start_version "$START_SH" "$next"
    write_version_file "$next"
    "$SYNC_SH"
    check_release
    echo "Prepared start.sh release $next. Review the diff, then commit the release files."
}

prepare_rollback() {
    local ref=$1 next=$2 current candidate candidate_version
    require_version "$next"
    git -C "$ROOT" cat-file -e "$ref:$START_REL" 2>/dev/null ||
        die "Git ref '$ref' does not contain $START_REL"

    current=$(extract_start_version "$START_SH")
    require_forward_version "$current" "$next"
    candidate=$(mktemp "${TMPDIR:-/tmp}/start-sh-rollback.XXXXXX")
    git -C "$ROOT" show "$ref:$START_REL" > "$candidate"
    chmod +x "$candidate"
    candidate_version=$(extract_start_version "$candidate")
    echo "Restoring $START_REL from $ref (payload version $candidate_version) as $next"
    bash -n "$candidate"
    write_start_version "$candidate" "$next"
    bash -n "$candidate"
    chmod --reference="$START_SH" "$candidate"
    mv "$candidate" "$START_SH"
    write_version_file "$next"
    "$SYNC_SH"
    check_release
    echo "Prepared rollback release $next. Review the diff, then commit the release files."
}

publish_release() {
    local branch
    branch=$(git -C "$ROOT" branch --show-current)
    [[ "$branch" == main ]] || die "publish must run on main (current branch: ${branch:-detached})"
    check_release
    git -C "$ROOT" diff-index --quiet HEAD -- "$START_REL" hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version ||
        die "release files have uncommitted changes; commit them before publishing"
    git -C "$ROOT" push origin main
    [[ -z "$(git -C "$ROOT" rev-list origin/main..HEAD)" ]] ||
        die "origin/main is not current after push"
    verify_distribution
    echo "Published and verified main through the Forgejo GitHub mirror."
}

case "${1:-}" in
    release)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        prepare_release "$2"
        ;;
    rollback)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        prepare_rollback "$2" "$3"
        ;;
    --check)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        check_release
        ;;
    distribution-check|verify-distribution|--distribution-check)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        verify_distribution
        ;;
    publish)
        [[ $# -eq 1 ]] || { usage >&2; exit 2; }
        publish_release
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
