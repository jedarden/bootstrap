#!/usr/bin/env bash
set -Eeuo pipefail

# Compare every mapped host's installed launcher with its lineage's signed
# release manifest. start-sh-release --check authenticates each local
# manifest before its digest is sent to the corresponding host.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TARGET_MAP="$ROOT/docs/release-rollout-targets.tsv"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ $# -eq 0 ]] || die "usage: scripts/verify-deployed-launchers.sh"
"$ROOT/scripts/check-rollout-targets.sh" --live >/dev/null

verified=0
while IFS=$'\t' read -r lineage target; do
    [[ -n "$lineage" && "$lineage" != \#* && "$lineage" != lineage ]] || continue

    host_dir="$ROOT/hosts/$lineage"
    [[ -d "$host_dir" ]] || die "lineage directory is missing: $lineage"
    "$ROOT/scripts/start-sh-release.sh" --host "$lineage" --check >/dev/null

    mapfile -t launcher_digests < <(
        awk '$1 == "artifact=start.sh" { print $2 }' "$host_dir/artifact-manifest.txt"
    )
    [[ ${#launcher_digests[@]} -eq 1 && "${launcher_digests[0]}" =~ ^[0-9a-f]{64}$ ]] ||
        die "$lineage signed manifest must contain exactly one valid start.sh digest"
    expected=${launcher_digests[0]}

    ssh "$target" "set -eu
        actual=\$(sha256sum \"\$HOME/start.sh\" | awk '{print \$1}')
        if [ \"\$actual\" != '$expected' ]; then
            printf '%s\\n' 'deployed launcher digest does not match the selected lineage manifest' >&2
            exit 1
        fi
        printf 'verified start.sh sha256=%s\\n' \"\$actual\"
    " || die "$target failed the $lineage launcher digest check"

    ((verified += 1))
done < <(awk -F '\t' 'NF == 2 { print }' "$TARGET_MAP")

(( verified > 0 )) || die "no rollout targets were verified"
echo "Verified signed launcher digest on $verified rollout target(s)."
