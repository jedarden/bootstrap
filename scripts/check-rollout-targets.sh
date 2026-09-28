#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the reviewed lineage-to-machine map before a release rollout.
# A lineage may have multiple machines, but a machine may belong to only one
# lineage. The map is deliberately data-only: it is never sourced as shell.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=worktree
MAP_RELATIVE=docs/release-rollout-targets.tsv
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-rollout-targets.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  scripts/check-rollout-targets.sh [--live|--staged]

Validate the reviewed lineage-to-SSH-target map against the immediate
directories under hosts/.

Options:
  --live, --worktree  Read hosts/ and the map from the working tree (default).
  --staged            Read hosts/ and the map from the Git index.
USAGE
}

source_copy() {
    local relative=$1 destination=$2
    if [[ "$SOURCE" == worktree ]]; then
        cp -- "$ROOT/$relative" "$destination"
    else
        git -C "$ROOT" show ":$relative" > "$destination"
    fi
}

source_host_names() {
    if [[ "$SOURCE" == worktree ]]; then
        [[ -d "$ROOT/hosts" ]] || die "hosts/ is missing in the $SOURCE source"
        find "$ROOT/hosts" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
    else
        git -C "$ROOT" ls-files --cached -- 'hosts/*' |
            awk -F/ 'NF >= 3 { print $2 }' |
            sort -u
    fi
}

while (($# > 0)); do
    case "$1" in
        --live|--worktree)
            SOURCE=worktree
            ;;
        --staged)
            SOURCE=staged
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

MAP="$TMP/targets.tsv"
source_copy "$MAP_RELATIVE" "$MAP" || die "$MAP_RELATIVE is missing from the $SOURCE source"

mapfile -t host_names < <(source_host_names)
(( ${#host_names[@]} > 0 )) || die "hosts/ contains no host lineages in the $SOURCE source"

declare -A known_lineage=()
for lineage in "${host_names[@]}"; do
    known_lineage["$lineage"]=1
done

declare -A lineage_has_target=()
declare -A target_lineage=()
errors=()
header_seen=0
row_count=0
line_number=0

while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    [[ -z "$line" || "$line" == \#* ]] && continue

    if (( ! header_seen )); then
        if [[ "$line" != $'lineage\ttarget' ]]; then
            errors+=("line $line_number must be the exact header: lineage<TAB>target")
        else
            header_seen=1
        fi
        continue
    fi

    IFS=$'\t' read -r lineage target extra <<< "$line"
    if [[ -z "${lineage:-}" || -z "${target:-}" || -n "${extra:-}" ]]; then
        errors+=("line $line_number is not exactly two tab-separated fields")
        continue
    fi
    if [[ ! "$lineage" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        errors+=("line $line_number has invalid lineage name: $lineage")
        continue
    fi
    if [[ ! "$target" =~ ^[a-z_][a-z0-9_-]*@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; then
        errors+=("line $line_number has an unknown or invalid SSH target: $target")
        continue
    fi

    ((row_count += 1))
    lineage_has_target["$lineage"]=1
    if [[ -z "${known_lineage[$lineage]+present}" ]]; then
        errors+=("line $line_number names unknown lineage: $lineage")
    fi

    target_host=${target#*@}
    if [[ -n "${target_lineage[$target_host]+present}" ]]; then
        previous_lineage=${target_lineage[$target_host]}
        if [[ "$previous_lineage" == "$lineage" ]]; then
            errors+=("line $line_number duplicates target host $target_host for lineage $lineage")
        else
            errors+=("line $line_number cross-lineage target host $target_host: already assigned to $previous_lineage, cannot assign to $lineage")
        fi
    else
        target_lineage["$target_host"]=$lineage
    fi
done < "$MAP"

(( header_seen )) || errors+=("map is missing the exact header: lineage<TAB>target")
(( row_count > 0 )) || errors+=("map contains no rollout targets")

for lineage in "${host_names[@]}"; do
    [[ -n "${lineage_has_target[$lineage]+present}" ]] ||
        errors+=("missing rollout target for lineage: $lineage")
done

if (( ${#errors[@]} > 0 )); then
    printf 'ERROR: rollout target map is invalid (%s source):\n' "$SOURCE" >&2
    printf '  - %s\n' "${errors[@]}" >&2
    exit 1
fi

echo "Rollout target map verified: $row_count targets for ${#host_names[@]} lineages ($SOURCE source)"
