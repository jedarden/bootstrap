#!/usr/bin/env bash
set -Eeuo pipefail

# Enforce the boundary in the committed bootstrap artifact without requiring
# operator-side SOPS or age binaries. Runtime coverage in the Docker
# integration test complements this structural check.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BOOTSTRAP="$ROOT/hosts/ex44/bootstrap.sh"

die() {
    echo "SOPS operator boundary test failed: $*" >&2
    exit 1
}

[[ -f "$BOOTSTRAP" ]] || die "bootstrap artifact is missing"

python3 - "$BOOTSTRAP" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path


bootstrap = Path(sys.argv[1])
text = bootstrap.read_text(encoding="utf-8")
errors: list[str] = []

private_marker = "AGE-SECRET-" + "KEY-"
if private_marker in text:
    errors.append("bootstrap contains an age private identity marker")

try:
    start = text.index("fetch_secrets_from_openbao()")
    end = text.index("\n}", start) + 2
except ValueError:
    errors.append("OpenBao fetch function is missing or malformed")
    openbao = ""
else:
    openbao = text[start:end]

if openbao:
    if not re.search(r"(?:^|\s)-X\s+GET(?:\s|$)", openbao):
        errors.append("OpenBao fetch is not explicitly read-only")
    if re.search(
        r"(?:^|\s)(?:-X|--request(?:=|\s+))(?:POST|PUT|PATCH|DELETE)(?:\s|$)",
        openbao,
        re.IGNORECASE,
    ):
        errors.append("OpenBao fetch contains a write HTTP method")
    if re.search(
        r"(?:^|\s)(?:-d|--data(?:=|\s+)|--upload-file(?:=|\s+)|--form(?:=|\s+))",
        openbao,
    ):
        errors.append("OpenBao fetch sends a request body")
    if re.search(
        r"(?:AGE-SECRET|SOPS_AGE|age[_-](?:private|secret|identity))",
        openbao,
        re.IGNORECASE,
    ):
        errors.append("OpenBao fetch handles age private identity material")

# Catch package-manager and installer additions even when a package list is
# spread over shell continuation lines.
lines = text.splitlines()
for index, line in enumerate(lines):
    if line.lstrip().startswith("#"):
        continue
    if not re.search(r"\b(?:apt-get\s+install|install_packages)\b", line):
        continue

    block = [line]
    cursor = index
    while block[-1].rstrip().endswith("\\") and cursor + 1 < len(lines):
        cursor += 1
        block.append(lines[cursor])
    package_block = "\n".join(block)
    if re.search(r"\b(?:sops|age|age-keygen)\b", package_block, re.IGNORECASE):
        errors.append("bootstrap installs SOPS or age tooling")
        break

if re.search(
    r"\b(?:curl|wget|tar|install)\b[^\n]*\b(?:sops|age(?:-keygen)?)\b",
    text,
    re.IGNORECASE,
):
    errors.append("bootstrap downloads or installs SOPS or age tooling")

if errors:
    for error in dict.fromkeys(errors):
        print(f"SOPS operator boundary violation: {error}", file=sys.stderr)
    raise SystemExit(1)

print("SOPS operator boundary contract passed")
PY

private_key_marker='AGE-SECRET-''KEY-'
while IFS= read -r -d '' artifact; do
    if grep -Fq -- "$private_key_marker" "$artifact"; then
        die "a provisioned host artifact contains an age private identity marker"
    fi
done < <(find "$ROOT/hosts/ex44" -type f -print0)

printf '%s\n' 'SOPS operator boundary tests passed'
