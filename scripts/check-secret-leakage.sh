#!/usr/bin/env bash
set -Eeuo pipefail

# Audit repository and release artifacts for secret material. The scanner is
# intentionally conservative: variable references, empty assignments, and
# documentation placeholders are safe; concrete values are not.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCAN_TRACKED=false
SCAN_ARTIFACTS=false
declare -a EXPLICIT_PATHS=()

usage() {
    cat <<'USAGE'
Usage:
  scripts/check-secret-leakage.sh [--tracked] [--artifacts] [--path PATH ...]

With no scope options, audit both all Git-tracked files and the generated host
artifacts under hosts/. --tracked audits the Git index. --artifacts audits
start.sh, bootstrap.sh, start.sh.version, and every versioned bootstrap archive
under each hosts/* directory. --path adds one file or directory explicitly.
USAGE
}

while (($# > 0)); do
    case "$1" in
        --tracked)
            SCAN_TRACKED=true
            ;;
        --artifacts)
            SCAN_ARTIFACTS=true
            ;;
        --path)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            EXPLICIT_PATHS+=("$2")
            shift
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

if [[ "$SCAN_TRACKED" == false && "$SCAN_ARTIFACTS" == false &&
    ${#EXPLICIT_PATHS[@]} -eq 0 ]]; then
    SCAN_TRACKED=true
    SCAN_ARTIFACTS=true
fi

declare -a FILES=()
declare -A SEEN=()

add_file() {
    local path=$1
    [[ -f "$path" ]] || return 0
    path=$(realpath -- "$path")
    [[ -n "${SEEN[$path]:-}" ]] && return 0
    SEEN[$path]=1
    FILES+=("$path")
}

if [[ "$SCAN_TRACKED" == true ]]; then
    if git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
        while IFS= read -r -d '' path; do
            add_file "$ROOT/$path"
        done < <(git -C "$ROOT" ls-files -z --cached)
    else
        # git archive extractions are committed snapshots but intentionally do
        # not contain .git. In that mode every extracted regular file is part
        # of the tracked snapshot being verified.
        while IFS= read -r -d '' path; do
            add_file "$path"
        done < <(find "$ROOT" -type f -not -path "$ROOT/.git/*" -print0)
    fi
fi

if [[ "$SCAN_ARTIFACTS" == true && -d "$ROOT/hosts" ]]; then
    while IFS= read -r -d '' host_dir; do
        for path in \
            "$host_dir/start.sh" \
            "$host_dir/bootstrap.sh" \
            "$host_dir/start.sh.version"; do
            add_file "$path"
        done
        while IFS= read -r -d '' path; do
            add_file "$path"
        done < <(find "$host_dir" -maxdepth 1 -type f -name 'bootstrap-*.sh' -print0)
    done < <(find "$ROOT/hosts" -mindepth 1 -maxdepth 1 -type d -print0)
fi

for path in "${EXPLICIT_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
        while IFS= read -r -d '' file; do
            add_file "$file"
        done < <(find "$path" -type f -print0)
    else
        add_file "$path"
    fi
done

((${#FILES[@]} > 0)) || {
    echo "Secret leakage audit: no files selected"
    exit 0
}

export SECRET_LEAKAGE_ROOT="$ROOT"
python3 - "${FILES[@]}" <<'PY'
from __future__ import annotations

import os
import pathlib
import re
import sys


# Keep sensitive marker strings assembled so the tracked-file scope does not
# report this audit's own source code.
age_private_prefix = "AGE-SECRET-" + "KEY-"


def is_placeholder(value: str) -> bool:
    value = value.strip().strip('"\'`')
    if not value:
        return True
    lower = value.lower()
    if value.startswith(("$", "${", "<", "%")):
        return True
    if value.endswith(">") or "${" in value:
        return True
    safe_words = (
        "changeme",
        "example",
        "fixture",
        "placeholder",
        "not-configured",
        "not_configured",
        "your-",
        "your_",
        "replace-",
        "replace_",
        "dummy",
        "fake",
        "test-",
        "test_",
    )
    return lower in {"null", "none", "unset"} or lower.startswith(safe_words)


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def scan(path: pathlib.Path) -> list[tuple[int, str]]:
    text = path.read_bytes().decode("utf-8", errors="replace")
    findings: list[tuple[int, str]] = []

    # A plaintext file in a secrets tree is never a valid tracked artifact.
    # Encrypted SOPS files must carry the explicit .sops suffix and metadata.
    root = pathlib.Path(os.environ["SECRET_LEAKAGE_ROOT"])
    try:
        relative = path.relative_to(root)
    except ValueError:
        relative = path
    parts = relative.parts
    if parts and parts[0] == "secrets" and len(parts) >= 3:
        if ".sops." not in path.name:
            findings.append((1, "plaintext file under secrets/"))
        elif "sops:" not in text or "ENC[" not in text:
            findings.append((1, "SOPS file is not encrypted"))
    elif (
        path.name != ".sops.yaml"
        and path.name.endswith((".sops.env", ".sops.yml", ".sops.yaml"))
        and ("sops:" not in text or "ENC[" not in text)
    ):
        findings.append((1, "SOPS file is not encrypted"))

    marker_at = text.find(age_private_prefix)
    if marker_at >= 0:
        findings.append((line_number(text, marker_at), "age private key"))

    # OpenBao/Vault token wire formats are high-confidence even when the token
    # is not assigned to a variable.
    token_patterns = (
        (re.compile(r"\bhvs\.[A-Za-z0-9._-]{20,}"), "OpenBao token"),
        (re.compile(r"\bhvb\.[A-Za-z0-9._-]{20,}"), "OpenBao token"),
        (re.compile(r"\bs\.[A-Za-z0-9]{20,}"), "Vault token"),
    )
    for pattern, reason in token_patterns:
        match = pattern.search(text)
        if match:
            findings.append((line_number(text, match.start()), reason))

    # Detect concrete values assigned to the sensitive fields used by the
    # bootstrap, Ansible, OpenBao, and restic paths. References and examples
    # are deliberately ignored so source and documentation can name fields.
    field = (
        r"(?:BOOTSTRAP_)?(?:B2_APPLICATION_KEY|B2_ACCOUNT_KEY|"
        r"RESTIC_PASSWORD|OPENBAO_TOKEN|VAULT_TOKEN)"
        r"|(?:b2_application_key|b2_account_key|restic_password|"
        r"openbao_token|vault_token)"
    )
    assignment = re.compile(
        rf"(?i)(?P<field>(?<![\w$\{{])(?:{field})\b)\s*[:=]\s*"
        r"(?P<value>\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}#]+)"
    )
    for match in assignment.finditer(text):
        value = match.group("value")
        if not is_placeholder(value):
            findings.append(
                (line_number(text, match.start()), f"secret assignment {match.group('field')}")
            )

    return findings


all_findings: list[tuple[pathlib.Path, int, str]] = []
for name in sys.argv[1:]:
    path = pathlib.Path(name)
    try:
        findings = scan(path)
    except OSError as exc:
        print(f"Secret leakage audit could not read {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    all_findings.extend((path, line, reason) for line, reason in findings)

if all_findings:
    for path, line, reason in all_findings:
        print(f"ERROR: secret material detected in {path}:{line} ({reason})", file=sys.stderr)
    sys.exit(1)

print(f"Secret leakage audit passed: {len(sys.argv) - 1} files checked")
PY
