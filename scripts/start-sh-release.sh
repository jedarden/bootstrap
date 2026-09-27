#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare, validate, and publish a hosts/ex44/start.sh release.
#
# The standalone start.sh is the source of truth. bootstrap.sh contains a
# generated copy, and start.sh.version is the version advertised to deployed
# launchers. Every release also archives the complete bootstrap script as
# bootstrap-<version>.sh. Keep all release metadata in agreement before
# committing or publishing.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOST_DIR="$ROOT/hosts/ex44"
START_SH="$HOST_DIR/start.sh"
BOOTSTRAP_SH="$HOST_DIR/bootstrap.sh"
VERSION_FILE="$HOST_DIR/start.sh.version"
SYNC_SH="$HOST_DIR/sync-start-sh.sh"
MANIFEST_FILE="$HOST_DIR/artifact-manifest.txt"
SIGNATURE_FILE="$HOST_DIR/artifact-manifest.sig"
SIGNING_PUBLIC_KEY="$HOST_DIR/keys/bootstrap-artifacts-signing.pub"
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
    'hosts/ex44/artifact-manifest.txt|artifact-manifest.txt'
    'hosts/ex44/artifact-manifest.sig|artifact-manifest.sig'
    'hosts/ex44/keys/jedarden.pub|keys/jedarden.pub'
    'hosts/ex44/keys/jeda-mbp.pub|keys/jeda-mbp.pub'
    'hosts/ex44/keys/bootstrap-artifacts-signing.pub|keys/bootstrap-artifacts-signing.pub'
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
  scripts/start-sh-release.sh manifest VERSION
  scripts/start-sh-release.sh rotation-check OLD-KEY-ID NEW-KEY-ID
  scripts/start-sh-release.sh --check
  scripts/start-sh-release.sh distribution-check
  scripts/start-sh-release.sh publish

Commands:
  release VERSION       Set the next start.sh version, regenerate the
                        bootstrap.sh metadata and heredoc, create its
                        bootstrap-VERSION.sh archive, and run all checks.
  rollback GIT-REF VERSION
                        Restore start.sh from GIT-REF, publish it under a new
                        forward version, regenerate bootstrap.sh, create its
                        archive, and check it.
  manifest VERSION     Re-sign the manifest for already-prepared release
                        artifacts. The signing key never belongs in Git.
  rotation-check OLD-KEY-ID NEW-KEY-ID
                        Validate that the prepared release is an overlap
                        release signed by OLD-KEY-ID and trusting NEW-KEY-ID.
  --check               Verify syntax, generated-copy equality, and that the
                        current archive contents and all release metadata agree.
  distribution-check    Verify Forgejo main is mirrored to GitHub and that
                        GitHub raw release artifacts match that commit.
  publish               Push the already-committed release to origin/main.
                        Then verify the Forgejo-to-GitHub distribution path;
                        this command does not push a second remote.

VERSION must be MAJOR.MINOR.PATCH and must be greater than the current
standalone version. A rollback therefore uses a new version even when its
payload came from an older Git commit; deployed launchers only move forward.

The host artifact checker validates every host directory independently, so
intentional host-specific splits do not require a special environment flag.
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

extract_bootstrap_version() {
    local path=$1 comment assignment
    local -a comments assignments

    mapfile -t comments < <(grep -E '^# Version: [0-9]+\.[0-9]+\.[0-9]+$' "$path" || true)
    [[ ${#comments[@]} -eq 1 ]] ||
        die "$path must contain exactly one bootstrap Version comment"
    comment=${comments[0]#\# Version: }

    mapfile -t assignments < <(grep -E '^VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$path" || true)
    [[ ${#assignments[@]} -eq 1 ]] ||
        die "$path must contain exactly one bootstrap VERSION assignment"
    assignment=${assignments[0]#VERSION=\"}
    assignment=${assignment%\"}

    [[ "$comment" == "$assignment" ]] ||
        die "$path bootstrap metadata disagrees: comment=$comment, VERSION=$assignment"
    printf '%s\n' "$comment"
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
    local standalone embedded advertised bootstrap archive archive_version archive_start
    standalone=$(extract_start_version "$START_SH")
    embedded=$(extract_start_version "$BOOTSTRAP_SH")
    advertised=$(read_advertised_version)
    bootstrap=$(extract_bootstrap_version "$BOOTSTRAP_SH")

    [[ "$standalone" == "$embedded" ]] ||
        die "embedded version $embedded disagrees with standalone version $standalone"
    [[ "$standalone" == "$advertised" ]] ||
        die "advertised version $advertised disagrees with standalone version $standalone"
    [[ "$standalone" == "$bootstrap" ]] ||
        die "bootstrap version $bootstrap disagrees with standalone version $standalone"

    archive="$HOST_DIR/bootstrap-$standalone.sh"
    [[ -f "$archive" ]] ||
        die "release archive is missing: $archive"
    [[ -x "$archive" ]] ||
        die "release archive is not executable: $archive"
    bash -n "$archive"
    archive_version=$(extract_bootstrap_version "$archive")
    archive_start=$(extract_start_version "$archive")
    [[ "$archive_version" == "$standalone" ]] ||
        die "archive version $archive_version disagrees with release version $standalone"
    [[ "$archive_start" == "$standalone" ]] ||
        die "archive embedded version $archive_start disagrees with release version $standalone"
    cmp -s "$BOOTSTRAP_SH" "$archive" ||
        die "release archive $archive is not an exact copy of bootstrap.sh"

    echo "Version agreement: start.sh=$standalone, bootstrap.sh=$bootstrap, start.sh.version=$advertised, archive=$standalone"
}

extract_artifact_key_id() {
    local path=$1 line
    mapfile -t lines < <(grep -E '^ARTIFACT_TRUSTED_KEY_ID="[A-Za-z0-9._-]+"$' "$path" || true)
    [[ ${#lines[@]} -ge 1 ]] || die "$path must contain an ARTIFACT_TRUSTED_KEY_ID assignment"
    for line in "${lines[@]}"; do
        [[ "$line" == "${lines[0]}" ]] || die "$path contains disagreeing ARTIFACT_TRUSTED_KEY_ID assignments"
    done
    line=${lines[0]#ARTIFACT_TRUSTED_KEY_ID=\"}
    printf '%s\n' "${line%\"}"
}

extract_trusted_key_count() {
    local path=$1

    python3 - "$path" <<'PY'
import re
import shlex
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
counts = []
for name in ("ARTIFACT_TRUSTED_KEY_IDS", "ARTIFACT_TRUSTED_PUBLIC_KEYS"):
    match = re.search(rf"(?ms)^{name}=\((.*?)\)$", text)
    if not match:
        raise SystemExit(f"{path} is missing {name} array")
    try:
        entries = shlex.split(match.group(1), comments=False, posix=True)
    except ValueError as exc:
        raise SystemExit(f"{path} has malformed {name} array: {exc}")
    if not entries:
        raise SystemExit(f"{path} has an empty {name} array")
    counts.append(len(entries))

if counts[0] != counts[1]:
    raise SystemExit(
        f"{path} has {counts[0]} trusted key IDs but {counts[1]} trusted public keys"
    )
print(counts[0])
PY
}

check_trusted_key_declarations() {
    local path count other_count
    count=$(extract_trusted_key_count "$START_SH") || die "invalid trusted-key declarations in $START_SH"
    other_count=$(extract_trusted_key_count "$BOOTSTRAP_SH") || die "invalid trusted-key declarations in $BOOTSTRAP_SH"
    [[ "$count" == "$other_count" ]] ||
        die "start.sh and bootstrap.sh declare different trusted-key counts"
}

check_immutable_archives() {
    local tracked path
    while IFS= read -r tracked; do
        [[ -n "$tracked" ]] || continue
        path="$ROOT/$tracked"
        [[ -f "$path" ]] ||
            die "immutable bootstrap archive is missing: $tracked (historical archives must not be deleted)"
    done < <(git -C "$ROOT" ls-files 'hosts/ex44/bootstrap-*.sh' 2>/dev/null || true)
}

check_rotation_release() {
    local old_key_id=$1 new_key_id=$2 primary count
    [[ "$old_key_id" =~ ^[A-Za-z0-9._-]+$ && "$new_key_id" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "rotation key IDs must contain only letters, numbers, '.', '_', or '-'"
    [[ "$old_key_id" != "$new_key_id" ]] ||
        die "rotation requires distinct old and new key IDs"

    check_release
    primary=$(extract_artifact_key_id "$START_SH")
    [[ "$primary" == "$old_key_id" ]] ||
        die "overlap release must remain signed by old key $old_key_id (found $primary)"
    [[ "$(extract_artifact_key_id "$BOOTSTRAP_SH")" == "$old_key_id" ]] ||
        die "bootstrap.sh does not retain old signing key ID $old_key_id"
    count=$(extract_trusted_key_count "$START_SH")
    (( count >= 2 )) ||
        die "overlap release must trust at least old and new keys"
    grep -Fq "$new_key_id" "$START_SH" ||
        die "start.sh does not embed new trusted key ID $new_key_id"
    grep -Fq "$new_key_id" "$BOOTSTRAP_SH" ||
        die "bootstrap.sh does not embed new trusted key ID $new_key_id"
    echo "Rotation overlap verified: signer=$old_key_id, next trusted key=$new_key_id, trusted-key-count=$count"
}

require_signing_key() {
    local signing_key=${ARTIFACT_SIGNING_KEY:-}
    [[ -n "$signing_key" && -f "$signing_key" ]] ||
        die "ARTIFACT_SIGNING_KEY must point to the release signing key (kept outside Git)"
    command -v openssl >/dev/null 2>&1 || die "openssl is required to sign the artifact manifest"
    command -v base64 >/dev/null 2>&1 || die "base64 is required to sign the artifact manifest"
}

manifest_artifacts() {
    printf '%s\n' \
        'bootstrap.sh' \
        'start.sh' \
        'start.sh.version' \
        'keys/jedarden.pub' \
        'keys/jeda-mbp.pub' \
        'keys/bootstrap-artifacts-signing.pub'
    find "$HOST_DIR" -maxdepth 1 -type f -name 'bootstrap-*.sh' -printf '%f\n' | sort
}

write_artifact_manifest() {
    local version=$1 signing_key=${ARTIFACT_SIGNING_KEY:-}
    local key_id path digest manifest_tmp signature_tmp signature_value
    local -a artifacts

    require_signing_key
    key_id=$(extract_artifact_key_id "$START_SH")
    [[ "$(extract_artifact_key_id "$BOOTSTRAP_SH")" == "$key_id" ]] ||
        die "bootstrap.sh and start.sh use different artifact signing key IDs"
    mapfile -t artifacts < <(manifest_artifacts "$version")
    manifest_tmp=$(mktemp "${TMPDIR:-/tmp}/artifact-manifest.XXXXXX")
    signature_tmp=$(mktemp "${TMPDIR:-/tmp}/artifact-signature.XXXXXX")
    {
        printf '%s\n' 'format=bootstrap-artifact-manifest-v1'
        printf 'key_id=%s\n' "$key_id"
        printf 'version=%s\n' "$version"
        for path in "${artifacts[@]}"; do
            digest=$(sha256sum "$HOST_DIR/$path" | awk '{print $1}')
            printf 'artifact=%s %s\n' "$path" "$digest"
        done
    } > "$manifest_tmp"
    openssl dgst -sha256 -sign "$signing_key" -out "$signature_tmp" "$manifest_tmp" >/dev/null 2>&1 || {
        rm -f "$manifest_tmp" "$signature_tmp"
        die "could not sign the artifact manifest"
    }
    signature_value=$(base64 -w0 "$signature_tmp")
    mv "$manifest_tmp" "$MANIFEST_FILE"
    {
        printf 'key_id=%s\n' "$key_id"
        printf 'signature=%s\n' "$signature_value"
    } > "$SIGNATURE_FILE"
    rm -f "$signature_tmp"
}

check_artifact_manifest() {
    local version=$1 key_id manifest_version signature_value
    local path expected signature_tmp
    local -a formats key_ids versions signature_ids signatures artifacts expected_artifacts

    [[ -f "$MANIFEST_FILE" && -f "$SIGNATURE_FILE" && -f "$SIGNING_PUBLIC_KEY" ]] ||
        die "signed artifact manifest files are missing"
    command -v openssl >/dev/null 2>&1 || die "openssl is required to verify the artifact manifest"
    command -v base64 >/dev/null 2>&1 || die "base64 is required to verify the artifact manifest"

    mapfile -t formats < <(grep -E '^format=bootstrap-artifact-manifest-v1$' "$MANIFEST_FILE" || true)
    mapfile -t key_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$MANIFEST_FILE" || true)
    mapfile -t versions < <(grep -E '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$MANIFEST_FILE" || true)
    [[ ${#formats[@]} -eq 1 && ${#key_ids[@]} -eq 1 && ${#versions[@]} -eq 1 ]] ||
        die "artifact manifest metadata is malformed"
    key_id=${key_ids[0]#key_id=}
    manifest_version=${versions[0]#version=}
    [[ "$manifest_version" == "$version" ]] ||
        die "artifact manifest version $manifest_version disagrees with release version $version"
    [[ "$key_id" == "$(extract_artifact_key_id "$START_SH")" ]] ||
        die "artifact manifest key ID does not match start.sh"

    mapfile -t signature_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$SIGNATURE_FILE" || true)
    mapfile -t signatures < <(grep -E '^signature=[A-Za-z0-9+/]+=*$' "$SIGNATURE_FILE" || true)
    [[ ${#signature_ids[@]} -eq 1 && ${#signatures[@]} -eq 1 &&
        "${signature_ids[0]#key_id=}" == "$key_id" ]] ||
        die "artifact manifest signature metadata is malformed"
    signature_value=${signatures[0]#signature=}
    signature_tmp=$(mktemp "${TMPDIR:-/tmp}/artifact-signature-check.XXXXXX")
    if ! printf '%s' "$signature_value" | base64 --decode > "$signature_tmp" 2>/dev/null ||
        ! openssl dgst -sha256 -verify "$SIGNING_PUBLIC_KEY" -signature "$signature_tmp" "$MANIFEST_FILE" >/dev/null 2>&1; then
        rm -f "$signature_tmp"
        die "artifact manifest signature verification failed"
    fi
    rm -f "$signature_tmp"

    mapfile -t artifacts < <(sed -n 's/^artifact=//p' "$MANIFEST_FILE" | sort)
    mapfile -t expected_artifacts < <(manifest_artifacts "$version" | sort)
    [[ ${#artifacts[@]} -eq ${#expected_artifacts[@]} ]] || die "artifact manifest has an unexpected artifact set"
    for path in "${expected_artifacts[@]}"; do
        expected=$(sha256sum "$HOST_DIR/$path" | awk '{print $1}')
        grep -Fxq "${path} ${expected}" <(printf '%s\n' "${artifacts[@]}") ||
            die "artifact manifest digest mismatch for $path"
    done
}

check_release() {
    bash -n "$START_SH"
    bash -n "$BOOTSTRAP_SH"
    check_trusted_key_declarations
    check_immutable_archives
    "$ROOT/scripts/check-secret-leakage.sh" --artifacts
    "$SYNC_SH" --check
    check_versions
    check_artifact_manifest "$(read_advertised_version)"
    "$ROOT/scripts/check-host-parity.sh"
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

distribution_tmp_file() {
    local prefix=$1 filename=$2
    filename=${filename//\//__}
    printf '%s/%s-%s\n' "$DISTRIBUTION_TMP" "$prefix" "$filename"
}

raw_artifacts_match() {
    local tmp=$1 archive_filename=$2 spec filename
    local -a artifacts=("${DISTRIBUTION_ARTIFACTS[@]}" "hosts/ex44/$archive_filename|$archive_filename")
    for spec in "${artifacts[@]}"; do
        filename=${spec#*|}
        mkdir -p "$(dirname "$(distribution_tmp_file actual "$filename")")"
        curl --fail --location --silent --show-error \
            "$GITHUB_RAW_ROOT/$filename" > "$(distribution_tmp_file actual "$filename")" 2>/dev/null || return 1
        cmp -s "$(distribution_tmp_file expected "$filename")" "$(distribution_tmp_file actual "$filename")" || return 1
    done
}

verify_distribution() {
    local expected_commit forgejo_commit github_commit expected_version expected_archive_filename
    local timeout poll deadline spec path filename
    local -a artifacts

    check_release
    expected_version=$(read_advertised_version)
    expected_archive_filename="bootstrap-$expected_version.sh"
    git -C "$ROOT" diff-index --quiet HEAD -- \
        hosts/ex44/bootstrap.sh hosts/ex44/start.sh hosts/ex44/start.sh.version \
        "hosts/ex44/$expected_archive_filename" hosts/ex44/artifact-manifest.txt \
        hosts/ex44/artifact-manifest.sig ||
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
    artifacts=("${DISTRIBUTION_ARTIFACTS[@]}" "hosts/ex44/$expected_archive_filename|$expected_archive_filename")
    for spec in "${artifacts[@]}"; do
        path=${spec%%|*}
        filename=${spec#*|}
        if ! git -C "$ROOT" show "$expected_commit:$path" > "$(distribution_tmp_file expected "$filename")"; then
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
            if [[ "$github_commit" == "$forgejo_commit" ]] && raw_artifacts_match "$DISTRIBUTION_TMP" "$expected_archive_filename"; then
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

write_bootstrap_version() {
    local path=$1 version=$2 tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-release.XXXXXX")
    sed -E \
        -e "s/^# Version: [0-9]+\.[0-9]+\.[0-9]+$/# Version: $version/" \
        -e "s/^VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"$/VERSION=\"$version\"/" \
        -e "s/bootstrap-[0-9]+\.[0-9]+\.[0-9]+\.sh/bootstrap-$version.sh/g" \
        "$path" > "$tmp"
    chmod --reference="$path" "$tmp"
    if ! [[ "$(extract_bootstrap_version "$tmp")" == "$version" ]]; then
        rm -f "$tmp"
        die "could not update bootstrap metadata in $path"
    fi
    mv "$tmp" "$path"
}

create_bootstrap_archive() {
    local version=$1 archive tmp
    archive="$HOST_DIR/bootstrap-$version.sh"
    tmp=$(mktemp "${TMPDIR:-/tmp}/bootstrap-archive.XXXXXX")
    cp "$BOOTSTRAP_SH" "$tmp"
    chmod --reference="$BOOTSTRAP_SH" "$tmp"
    chmod +x "$tmp"
    mv "$tmp" "$archive"
}

prepare_release() {
    local next=$1 current
    require_version "$next"
    # Audit before changing any release file so a poisoned source artifact
    # fails closed without leaving a partially prepared release.
    "$ROOT/scripts/check-secret-leakage.sh" --artifacts
    bash -n "$START_SH"
    require_signing_key
    current=$(extract_start_version "$START_SH")
    require_forward_version "$current" "$next"

    write_start_version "$START_SH" "$next"
    write_version_file "$next"
    write_bootstrap_version "$BOOTSTRAP_SH" "$next"
    "$SYNC_SH"
    create_bootstrap_archive "$next"
    write_artifact_manifest "$next"
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
    require_signing_key
    candidate=$(mktemp "${TMPDIR:-/tmp}/start-sh-rollback.XXXXXX")
    git -C "$ROOT" show "$ref:$START_REL" > "$candidate"
    chmod +x "$candidate"
    candidate_version=$(extract_start_version "$candidate")
    echo "Restoring $START_REL from $ref (payload version $candidate_version) as $next"
    bash -n "$candidate"
    "$ROOT/scripts/check-secret-leakage.sh" --path "$candidate"
    write_start_version "$candidate" "$next"
    bash -n "$candidate"
    chmod --reference="$START_SH" "$candidate"
    mv "$candidate" "$START_SH"
    write_version_file "$next"
    write_bootstrap_version "$BOOTSTRAP_SH" "$next"
    "$SYNC_SH"
    create_bootstrap_archive "$next"
    write_artifact_manifest "$next"
    check_release
    echo "Prepared rollback release $next. Review the diff, then commit the release files."
}

publish_release() {
    local branch version archive_filename
    branch=$(git -C "$ROOT" branch --show-current)
    [[ "$branch" == main ]] || die "publish must run on main (current branch: ${branch:-detached})"
    check_release
    version=$(read_advertised_version)
    archive_filename="bootstrap-$version.sh"
    git -C "$ROOT" ls-files --error-unmatch "hosts/ex44/$archive_filename" >/dev/null 2>&1 ||
        die "release archive is not tracked: hosts/ex44/$archive_filename"
    git -C "$ROOT" diff-index --quiet HEAD -- "$START_REL" hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version \
        "hosts/ex44/$archive_filename" hosts/ex44/artifact-manifest.txt \
        hosts/ex44/artifact-manifest.sig ||
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
    manifest)
        [[ $# -eq 2 ]] || { usage >&2; exit 2; }
        require_version "$2"
        write_artifact_manifest "$2"
        check_release
        ;;
    rotation-check)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        check_rotation_release "$2" "$3"
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
