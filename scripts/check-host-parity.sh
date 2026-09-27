#!/usr/bin/env bash
set -Eeuo pipefail

# Compare the bootstrap release artifacts for the canonical ex44 host and a
# staged host-specific lab directory.  With no hosts/lab directory, lab is
# still consuming the one canonical ex44 directory and there is no second
# copy to compare.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=worktree
ALLOW_SPLIT=false
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-host-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  scripts/check-host-parity.sh [--live|--staged] [--allow-split]

Compare bootstrap.sh, start.sh, start.sh.version, and every versioned
bootstrap archive under hosts/ex44 and hosts/lab.

Options:
  --live          Read the current working tree (the default).
  --staged        Read the Git index, ignoring unstaged working-tree edits.
  --allow-split   Permit differences when hosts/lab exists. Use only after
                  intentionally creating the host-specific directory; each
                  host's internal artifact/version checks still run.
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
        git -C "$ROOT" ls-files --cached -- "$directory/" | grep -q .
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
    local directory=$1
    if [[ "$SOURCE" == worktree ]]; then
        find "$(source_path "$directory")" -mindepth 1 -maxdepth 1 -type f -printf '%P\n' | sort
    else
        git -C "$ROOT" ls-files --cached -- "$directory/" |
            sed "s#^${directory}/##" |
            sort
    fi
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

host_manifest() {
    local directory=$1 output=$2 filename all_files
    all_files="$output.all"
    source_dir_exists "$directory" || die "$directory is missing in the $SOURCE source"

    source_files "$directory" > "$all_files"
    : > "$output"
    while IFS= read -r filename; do
        case "$filename" in
            bootstrap.sh|start.sh|start.sh.version)
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
    for filename in bootstrap.sh start.sh start.sh.version; do
        grep -Fxq "$filename" "$output" ||
            die "$directory/$filename is missing in the $SOURCE source"
    done

    grep -Eq '^bootstrap-[0-9]+\.[0-9]+\.[0-9]+\.sh$' "$output" ||
        die "$directory has no versioned bootstrap archive"
}

validate_host() {
    local directory=$1 label=$2 manifest="$TMP/$2.manifest" host_dir="$TMP/$2"
    local version archive archive_version bootstrap_version
    local filename
    local -a archives

    host_manifest "$directory" "$manifest"
    mkdir -p "$host_dir"
    while IFS= read -r filename; do
        source_copy "$directory/$filename" "$host_dir/$filename"
        source_is_executable "$directory/$filename" ||
            [[ "$filename" == start.sh.version ]] ||
            die "$directory/$filename is not executable in the $SOURCE source"
    done < "$manifest"

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
    printf '%s\n' "$version"
}

compare_hosts() {
    local ex44_manifest=$1 lab_manifest=$2 filename ex44_exec lab_exec
    cmp -s "$ex44_manifest" "$lab_manifest" ||
        die "ex44 and lab artifact manifests differ"

    while IFS= read -r filename; do
        cmp -s "$TMP/ex44/$filename" "$TMP/lab/$filename" ||
            die "ex44 and lab artifacts differ: $filename"
        ex44_exec=false
        lab_exec=false
        [[ -x "$TMP/ex44/$filename" ]] && ex44_exec=true
        [[ -x "$TMP/lab/$filename" ]] && lab_exec=true
        if [[ "$ex44_exec" != "$lab_exec" ]]; then
            die "ex44 and lab executable modes differ: $filename"
        fi
    done < "$ex44_manifest"
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
            ALLOW_SPLIT=true
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

EX44_MANIFEST="$TMP/ex44.manifest"
LAB_MANIFEST="$TMP/lab.manifest"
validate_host hosts/ex44 ex44 >/dev/null

if ! source_dir_exists hosts/lab; then
    echo "Host artifact parity verified: lab uses the canonical hosts/ex44 directory"
    exit 0
fi

validate_host hosts/lab lab >/dev/null
if [[ "$ALLOW_SPLIT" == true ]]; then
    echo "Host artifact parity intentionally skipped: hosts/lab is a split directory"
    exit 0
fi

host_manifest hosts/ex44 "$EX44_MANIFEST"
host_manifest hosts/lab "$LAB_MANIFEST"
compare_hosts "$EX44_MANIFEST" "$LAB_MANIFEST"
echo "Host artifact parity verified: ex44 and lab are byte-identical"
