#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the release artifacts in every host directory. Host directories
# are independent lineages: a host-specific split is valid as long as that
# host's own artifacts remain internally consistent.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=worktree
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-host-artifacts.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  scripts/check-host-parity.sh [--live|--staged] [--allow-split]

Validate bootstrap.sh, start.sh, start.sh.version, the signed artifact
manifest, and every versioned bootstrap archive in every immediate directory
under hosts/. The root
README.md must link to every host directory, and every README host link must
point to an existing host path.

Options:
  --live          Read the current working tree (the default).
  --staged        Read the Git index, ignoring unstaged working-tree edits.
  --allow-split   Backwards-compatible no-op; host directories are validated
                  independently and are not required to be byte-identical.
USAGE
}

source_path() {
    local relative=$1
    printf '%s/%s\n' "$ROOT" "$relative"
}

source_file_exists() {
    local relative=$1
    if [[ "$SOURCE" == worktree ]]; then
        [[ -f "$(source_path "$relative")" ]]
    else
        git -C "$ROOT" cat-file -e ":$relative" 2>/dev/null
    fi
}

source_dir_exists() {
    local directory=$1
    if [[ "$SOURCE" == worktree ]]; then
        [[ -d "$(source_path "$directory")" ]]
    else
        [[ -n "$(git -C "$ROOT" ls-files --cached -- "$directory/*")" ]]
    fi
}

source_path_exists() {
    local relative=$1
    if [[ "$SOURCE" == worktree ]]; then
        [[ -e "$(source_path "$relative")" ]]
    else
        git -C "$ROOT" cat-file -e ":$relative" 2>/dev/null ||
            [[ -n "$(git -C "$ROOT" ls-files --cached -- "$relative/*")" ]]
    fi
}

source_copy() {
    local relative=$1 destination=$2
    if [[ "$SOURCE" == worktree ]]; then
        cp -- "$(source_path "$relative")" "$destination"
    else
        git -C "$ROOT" show ":$relative" > "$destination"
    fi
}

source_is_executable() {
    local relative=$1 mode
    if [[ "$SOURCE" == worktree ]]; then
        [[ -x "$(source_path "$relative")" ]]
        return
    fi

    mode=$(git -C "$ROOT" ls-files --stage -- "$relative" | awk 'NR == 1 { print $1 }')
    [[ "$mode" == 100755 ]]
}

source_files() {
    local directory=$1 path prefix relative
    if [[ "$SOURCE" == worktree ]]; then
        find "$(source_path "$directory")" -mindepth 1 -maxdepth 1 -type f -printf '%P\n' | sort
        return
    fi

    prefix="$directory/"
    while IFS= read -r path; do
        [[ "$path" == "$prefix"* ]] || continue
        relative=${path#"$prefix"}
        [[ "$relative" != */* ]] || continue
        printf '%s\n' "$relative"
    done < <(git -C "$ROOT" ls-files --cached -- "$prefix*")
}

source_host_dirs() {
    local path
    if [[ "$SOURCE" == worktree ]]; then
        [[ -d "$ROOT/hosts" ]] || die "hosts/ is missing in the $SOURCE source"
        find "$ROOT/hosts" -mindepth 1 -maxdepth 1 -type d -printf 'hosts/%f\n' | sort
        return
    fi

    git -C "$ROOT" ls-files --cached -- 'hosts/*' |
        awk -F/ 'NF >= 3 { print "hosts/" $2 }' |
        sort -u
}

read_version_file() {
    local relative=$1 output
    output="$TMP/version-$(basename "$(dirname "$relative")")"
    source_copy "$relative" "$output"
    mapfile -t lines < "$output"
    [[ ${#lines[@]} -eq 1 && "${lines[0]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        die "$relative must contain exactly one MAJOR.MINOR.PATCH line"
    printf '%s\n' "${lines[0]}"
}

extract_assignment() {
    local path=$1 pattern=$2 label=$3
    mapfile -t lines < <(grep -E "$pattern" "$path" || true)
    [[ ${#lines[@]} -eq 1 ]] || die "$label must contain exactly one matching metadata assignment"
    printf '%s\n' "${lines[0]}"
}

extract_start_version() {
    local path=$1 line
    line=$(extract_assignment "$path" '^START_SH_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$path START_SH_VERSION")
    line=${line#START_SH_VERSION=\"}
    printf '%s\n' "${line%\"}"
}

extract_bootstrap_version() {
    local path=$1 comment assignment
    comment=$(extract_assignment "$path" '^# Version: [0-9]+\.[0-9]+\.[0-9]+$' "$path Version comment")
    assignment=$(extract_assignment "$path" '^VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$path VERSION")
    comment=${comment#\# Version: }
    assignment=${assignment#VERSION=\"}
    assignment=${assignment%\"}
    [[ "$comment" == "$assignment" ]] ||
        die "$path bootstrap metadata disagrees: comment=$comment, VERSION=$assignment"
    printf '%s\n' "$comment"
}

check_embedded_launcher() {
    local bootstrap=$1 start=$2
    python3 - "$bootstrap" "$start" <<'PY'
import pathlib
import sys

bootstrap = pathlib.Path(sys.argv[1]).read_text()
start = pathlib.Path(sys.argv[2]).read_text()
begin = "    cat > \"/home/$user/start.sh\" << 'STARTSH'\n"
end = "\nSTARTSH\n"
begin_at = bootstrap.find(begin)
if begin_at < 0:
    raise SystemExit("bootstrap.sh is missing the start.sh heredoc opening marker")
body_start = begin_at + len(begin)
body_end = bootstrap.find(end, body_start)
if body_end < 0:
    raise SystemExit("bootstrap.sh is missing the start.sh heredoc closing marker")
embedded = bootstrap[body_start:body_end + 1]
if embedded != start:
    raise SystemExit("bootstrap.sh embedded start.sh copy differs from start.sh")
PY
}

extract_launcher_key_id() {
    local path=$1 line
    local -a lines

    mapfile -t lines < <(grep -E '^ARTIFACT_TRUSTED_KEY_ID="[A-Za-z0-9._-]+"$' "$path" || true)
    [[ ${#lines[@]} -gt 0 ]] || die "$path must contain an ARTIFACT_TRUSTED_KEY_ID assignment"
    for line in "${lines[@]}"; do
        [[ "$line" == "${lines[0]}" ]] ||
            die "$path contains disagreeing ARTIFACT_TRUSTED_KEY_ID assignments"
    done
    line=${lines[0]#ARTIFACT_TRUSTED_KEY_ID=\"}
    printf '%s\n' "${line%\"}"
}

verify_artifact_manifest() {
    local host_dir=$1 manifest=$2 version=$3 label=$4 expected_set=$5
    local key_id manifest_version signature_key_id signature_value
    local line artifact digest path expected actual
    local -a formats key_ids versions signature_ids signatures artifact_lines
    local -a expected_artifacts actual_artifacts
    local signature_bin="$TMP/$label.signature.bin"
    local expected_list="$TMP/$label.expected-artifacts"
    local actual_list="$TMP/$label.actual-artifacts"

    command -v base64 >/dev/null 2>&1 || die 'base64 is required to verify artifact manifests'
    command -v openssl >/dev/null 2>&1 || die 'openssl is required to verify artifact manifests'
    command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required to verify artifact manifests'

    while IFS= read -r line; do
        case "$line" in
            format=*|key_id=*|version=*|artifact=*) ;;
            *) die "$manifest contains an unexpected manifest line" ;;
        esac
    done < "$manifest"

    mapfile -t formats < <(grep -E '^format=bootstrap-artifact-manifest-v1$' "$manifest" || true)
    mapfile -t key_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$manifest" || true)
    mapfile -t versions < <(grep -E '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$manifest" || true)
    [[ ${#formats[@]} -eq 1 && ${#key_ids[@]} -eq 1 && ${#versions[@]} -eq 1 ]] ||
        die "$manifest metadata is malformed"
    key_id=${key_ids[0]#key_id=}
    manifest_version=${versions[0]#version=}
    [[ "$manifest_version" == "$version" ]] ||
        die "$manifest version $manifest_version disagrees with $host_dir/start.sh.version $version"
    [[ "$key_id" == "$(extract_launcher_key_id "$host_dir/start.sh")" ]] ||
        die "$manifest key ID does not match $host_dir/start.sh"
    [[ "$key_id" == "$(extract_launcher_key_id "$host_dir/bootstrap.sh")" ]] ||
        die "$manifest key ID does not match $host_dir/bootstrap.sh"

    mapfile -t signature_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$host_dir/artifact-manifest.sig" || true)
    mapfile -t signatures < <(grep -E '^signature=[A-Za-z0-9+/]+=*$' "$host_dir/artifact-manifest.sig" || true)
    [[ ${#signature_ids[@]} -eq 1 && ${#signatures[@]} -eq 1 ]] ||
        die "$host_dir/artifact-manifest.sig metadata is malformed"
    signature_key_id=${signature_ids[0]#key_id=}
    [[ "$signature_key_id" == "$key_id" ]] ||
        die "$host_dir/artifact-manifest.sig key ID does not match $manifest"
    signature_value=${signatures[0]#signature=}
    printf '%s' "$signature_value" | base64 --decode > "$signature_bin" 2>/dev/null ||
        die "$host_dir/artifact-manifest.sig is not valid base64"
    openssl dgst -sha256 \
        -verify "$host_dir/keys/bootstrap-artifacts-signing.pub" \
        -signature "$signature_bin" "$manifest" >/dev/null 2>&1 ||
        die "$manifest detached signature does not verify with its pinned public key"

    mapfile -t artifact_lines < <(grep -E '^artifact=' "$manifest" || true)
    (( ${#artifact_lines[@]} > 0 )) || die "$manifest contains no artifact entries"
    : > "$actual_list"
    for line in "${artifact_lines[@]}"; do
        [[ "$line" =~ ^artifact=([^[:space:]]+)[[:space:]]([0-9a-f]{64})$ ]] ||
            die "$manifest contains a malformed artifact entry"
        artifact=${BASH_REMATCH[1]}
        digest=${BASH_REMATCH[2]}
        printf '%s\n' "$artifact" >> "$actual_list"
        printf '%s\n' "${artifact}|${digest}" >> "$actual_list.entries"
    done

    {
        while IFS= read -r path; do
            case "$path" in
                artifact-manifest.txt|artifact-manifest.sig)
                    continue
                    ;;
            esac
            printf '%s\n' "$path"
        done < "$expected_set"
        printf '%s\n' \
            keys/jedarden.pub \
            keys/jeda-mbp.pub \
            keys/bootstrap-artifacts-signing.pub
    } | sort > "$expected_list"
    sort "$actual_list" > "$actual_list.sorted"
    mapfile -t expected_artifacts < "$expected_list"
    mapfile -t actual_artifacts < "$actual_list.sorted"
    [[ "${expected_artifacts[*]}" == "${actual_artifacts[*]}" ]] ||
        die "$manifest artifact coverage does not match the host release set"

    while IFS='|' read -r artifact digest; do
        path="$host_dir/$artifact"
        [[ -f "$path" ]] || die "$manifest names missing artifact $artifact"
        expected=$(sha256sum "$path" | awk '{print $1}')
        [[ "$expected" == "$digest" ]] ||
            die "$manifest digest mismatch for $host_dir/$artifact"
    done < "$actual_list.entries"
}

host_manifest() {
    local directory=$1 output=$2 filename all_files
    all_files="$output.all"
    source_dir_exists "$directory" || die "$directory is missing in the $SOURCE source"

    source_files "$directory" > "$all_files"
    : > "$output"
    while IFS= read -r filename; do
        case "$filename" in
            bootstrap.sh|start.sh|start.sh.version|artifact-manifest.txt|artifact-manifest.sig)
                printf '%s\n' "$filename" >> "$output"
                ;;
            bootstrap-*.sh)
                [[ "$filename" =~ ^bootstrap-[0-9]+\.[0-9]+\.[0-9]+\.sh$ ]] ||
                    die "$directory contains an invalid versioned archive name: $filename"
                printf '%s\n' "$filename" >> "$output"
                ;;
        esac
    done < "$all_files"
    sort -o "$output" "$output"

    for filename in bootstrap.sh start.sh start.sh.version artifact-manifest.txt artifact-manifest.sig; do
        grep -Fxq "$filename" "$output" ||
            die "$directory/$filename is missing in the $SOURCE source"
    done
    for filename in jedarden.pub jeda-mbp.pub bootstrap-artifacts-signing.pub; do
        source_path_exists "$directory/keys/$filename" ||
            die "$directory/keys/$filename is missing in the $SOURCE source"
    done
    grep -Eq '^bootstrap-[0-9]+\.[0-9]+\.[0-9]+\.sh$' "$output" ||
        die "$directory has no versioned bootstrap archive"
}

validate_host() {
    local directory=$1 label=$2 manifest="$TMP/$2.manifest" host_dir="$TMP/$2"
    local version archive archive_version bootstrap_version
    local filename key_filename
    local -a archives

    host_manifest "$directory" "$manifest"
    mkdir -p "$host_dir"
    while IFS= read -r filename; do
        source_copy "$directory/$filename" "$host_dir/$filename"
        source_is_executable "$directory/$filename" ||
            [[ "$filename" == start.sh.version ||
                "$filename" == artifact-manifest.txt ||
                "$filename" == artifact-manifest.sig ]] ||
            die "$directory/$filename is not executable in the $SOURCE source"
    done < "$manifest"
    mkdir -p "$host_dir/keys"
    for key_filename in jedarden.pub jeda-mbp.pub bootstrap-artifacts-signing.pub; do
        source_copy "$directory/keys/$key_filename" "$host_dir/keys/$key_filename"
    done

    bash -n "$host_dir/start.sh"
    bash -n "$host_dir/bootstrap.sh"
    version=$(read_version_file "$directory/start.sh.version")
    [[ "$(extract_start_version "$host_dir/start.sh")" == "$version" ]] ||
        die "$directory/start.sh version disagrees with start.sh.version"
    bootstrap_version=$(extract_bootstrap_version "$host_dir/bootstrap.sh")
    [[ "$bootstrap_version" == "$version" ]] ||
        die "$directory/bootstrap.sh version disagrees with start.sh.version"
    [[ "$(extract_start_version "$host_dir/bootstrap.sh")" == "$version" ]] ||
        die "$directory/bootstrap.sh embedded launcher version disagrees with start.sh.version"
    check_embedded_launcher "$host_dir/bootstrap.sh" "$host_dir/start.sh"

    mapfile -t archives < <(grep -E '^bootstrap-[0-9]+\.[0-9]+\.[0-9]+\.sh$' "$manifest")
    for filename in "${archives[@]}"; do
        archive="$host_dir/$filename"
        bash -n "$archive"
        archive_version=${filename#bootstrap-}
        archive_version=${archive_version%.sh}
        [[ "$(extract_bootstrap_version "$archive")" == "$archive_version" ]] ||
            die "$directory/$filename metadata disagrees with its filename"
    done

    archive="$host_dir/bootstrap-$version.sh"
    [[ -f "$archive" ]] || die "$directory is missing the current bootstrap-$version.sh archive"
    cmp -s "$host_dir/bootstrap.sh" "$archive" ||
        die "$directory/bootstrap-$version.sh is not an exact copy of bootstrap.sh"
    verify_artifact_manifest "$host_dir" "$host_dir/artifact-manifest.txt" "$version" "$label" "$manifest"
    printf '%s\n' "$version"
}

check_readme_host_links() {
    local readme="$TMP/README.md" host path
    local links="$TMP/readme-host-links"

    source_file_exists README.md || die "README.md is missing in the $SOURCE source"
    source_copy README.md "$readme"
    python3 - "$readme" "$TMP/hosts" > "$links" <<'PY'
import pathlib
import posixpath
import re
import sys
import urllib.parse

readme = pathlib.Path(sys.argv[1])
host_dirs = [line.strip() for line in pathlib.Path(sys.argv[2]).read_text().splitlines() if line.strip()]
host_names = {directory.removeprefix("hosts/") for directory in host_dirs}
link_pattern = re.compile(r"\[[^\]]*\]\(\s*(?:<([^>\n]+)>|([^\s)\n]+))")
found = set()

for match in link_pattern.finditer(readme.read_text()):
    target = match.group(1) or match.group(2)
    target = urllib.parse.unquote(target.strip())
    parsed = urllib.parse.urlsplit(target)
    if parsed.scheme or parsed.netloc or target.startswith("#"):
        continue
    target = parsed.path
    if target.startswith("/"):
        target = target[1:]
    target = posixpath.normpath(target)
    parts = [part for part in target.split("/") if part not in ("", ".")]
    if not parts or parts[0] != "hosts":
        continue
    if len(parts) < 2:
        raise SystemExit(f"README host link has no host directory: {target}")
    host = parts[1]
    if host not in host_names:
        raise SystemExit(f"README links to missing host directory: {target}")
    found.add(host)
    print(f"{host}\t{target}")

missing = sorted(host_names - found)
if missing:
    raise SystemExit("README is missing host links: " + ", ".join(missing))
PY

    while IFS=$'\t' read -r host path; do
        [[ -n "$host" && -n "$path" ]] || continue
        source_path_exists "$path" || die "README host link does not exist: $path"
    done < "$links"

    while IFS= read -r directory; do
        host=${directory#hosts/}
        grep -Fq "${host}"$'\t' "$links" || die "README is missing a link for $directory"
    done < "$TMP/hosts"
}

while (($# > 0)); do
    case "$1" in
        --live|--worktree)
            SOURCE=worktree
            ;;
        --staged)
            SOURCE=staged
            ;;
        --allow-split|--intentional-split)
            # Kept so existing release commands remain compatible. There is
            # no cross-host byte comparison to opt out of anymore.
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

source_host_dirs > "$TMP/hosts"
mapfile -t host_dirs < "$TMP/hosts"
(( ${#host_dirs[@]} > 0 )) || die "hosts/ contains no host directories in the $SOURCE source"

for directory in "${host_dirs[@]}"; do
    label=${directory//\//_}
    version_file="$TMP/$label.version"
    validate_host "$directory" "$label" > "$version_file"
    version=$(<"$version_file")
    echo "$directory artifact set verified (version $version)"
done

check_readme_host_links
if (( ${#host_dirs[@]} == 1 )); then
    suffix=directory
else
    suffix=directories
fi
echo "Host artifact completeness verified: ${#host_dirs[@]} host $suffix"
