#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the repository's documented SOPS contract without decrypting any
# secret. The check reads the Git index when run in a checkout, so ignored or
# unstaged plaintext copies cannot affect the result. A git archive extraction
# has no index; in that case every regular file in the extraction is treated
# as part of the committed snapshot.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONTRACT_ROOT=${SOPS_CONTRACT_ROOT:-$ROOT}

while (($# > 0)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || {
                echo 'usage: scripts/check-sops-contract.sh [--root PATH]' >&2
                exit 2
            }
            CONTRACT_ROOT=$2
            shift
            ;;
        --help|-h)
            echo 'usage: scripts/check-sops-contract.sh [--root PATH]'
            exit 0
            ;;
        *)
            echo 'usage: scripts/check-sops-contract.sh [--root PATH]' >&2
            exit 2
            ;;
    esac
    shift
done

CONTRACT_ROOT=$(cd "$CONTRACT_ROOT" && pwd)
export CONTRACT_ROOT

python3 - <<'PY'
from __future__ import annotations

import os
import pathlib
import re
import subprocess
import sys


root = pathlib.Path(os.environ["CONTRACT_ROOT"])
errors: list[str] = []

SOPS_SUFFIXES = (".sops.env", ".sops.yml", ".sops.yaml")
AGE_RECIPIENT = re.compile(r"\bage1[0-9a-z]{58}\b")
ENC_VALUE = re.compile(r"^ENC\[[^\r\n\]]+\]$")
DOTENV_FIELD = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
SENSITIVE_ASSIGNMENT = re.compile(
    r"(?i)(?P<field>(?<![\w$\{])(?:BOOTSTRAP_)?(?:B2_APPLICATION_KEY|"
    r"B2_ACCOUNT_KEY|RESTIC_PASSWORD|OPENBAO_TOKEN|VAULT_TOKEN|"
    r"b2_application_key|b2_account_key|restic_password|openbao_token|"
    r"vault_token)\b)\s*[:=]\s*"
    r"(?P<value>\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}#]+)"
)

# Keep this marker assembled so the validator does not report its own source
# as a private key when the clean archive fallback scans every file.
AGE_PRIVATE_MARKER = "AGE-SECRET-" + "KEY-"
BOOTSTRAP_B2_KEY = "BOOTSTRAP_" + "B2_APPLICATION_KEY"
BOOTSTRAP_RESTIC_KEY = "BOOTSTRAP_" + "RESTIC_PASSWORD"
BOOTSTRAP_KEYS = {BOOTSTRAP_B2_KEY, BOOTSTRAP_RESTIC_KEY}


def tracked_paths() -> list[pathlib.Path]:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        result = None

    if result is not None:
        try:
            output = subprocess.check_output(
                ["git", "-C", str(root), "ls-files", "-z", "--cached"],
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            errors.append(f"could not read the Git index: {exc}")
            return []
        return [
            path
            for name in output.decode().split("\0")
            if name
            for path in [root / pathlib.Path(name)]
            if path.is_file()
        ]

    return [
        path
        for path in root.rglob("*")
        if path.is_file() and ".git" not in path.relative_to(root).parts
    ]


def relative(path: pathlib.Path) -> str:
    return path.relative_to(root).as_posix()


def read_text(path: pathlib.Path) -> str:
    try:
        return path.read_bytes().decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        errors.append(f"{relative(path)} is not readable UTF-8: {exc}")
        return ""


def is_placeholder(value: str) -> bool:
    value = value.strip().strip("\"'`")
    if not value or value.startswith(("$", "${", "<", "%")):
        return True
    lower = value.lower()
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
    return value.startswith("ENC[") or lower in {"null", "none", "unset"} or lower.startswith(safe_words)


paths = tracked_paths()
tracked = {relative(path): path for path in paths}
texts: dict[str, str] = {}

for path in paths:
    rel = relative(path)
    text = read_text(path)
    texts[rel] = text
    if AGE_PRIVATE_MARKER in text:
        errors.append(f"{rel} contains an age private identity")

    for match in SENSITIVE_ASSIGNMENT.finditer(text):
        if not is_placeholder(match.group("value")):
            errors.append(f"{rel} contains a plaintext secret assignment")
            break

secret_files: list[tuple[str, str]] = []
for rel, text in texts.items():
    path = pathlib.PurePosixPath(rel)
    name = path.name

    if path.parts and path.parts[0] == "secrets":
        if len(path.parts) != 3 or not name.endswith(SOPS_SUFFIXES):
            errors.append(f"{rel} is not an allowed encrypted file under secrets/")
            continue

    if rel == ".sops.yaml":
        continue
    if name.endswith(SOPS_SUFFIXES):
        secret_files.append((rel, text))

        # SOPS dotenv output stores its metadata as sops_* fields; YAML and
        # JSON output use a top-level sops mapping. Require both the metadata
        # marker and at least one encrypted value so a renamed plaintext file
        # cannot pass by carrying only a recipient-looking string.
        has_metadata = bool(
            re.search(r"(?m)^(?:sops:|sops_[A-Za-z0-9_]+(?:=|:)|[ \t]*[\"']?sops[\"']?[ \t]*:)", text)
        )
        if not has_metadata or "ENC[" not in text:
            errors.append(f"{rel} is not encrypted SOPS data")

        if rel.startswith("secrets/bootstrap/") and name.endswith(".sops.env"):
            fields: dict[str, list[str]] = {}
            for line in text.splitlines():
                match = DOTENV_FIELD.match(line)
                if not match or match.group(1).startswith("sops_"):
                    continue
                fields.setdefault(match.group(1), []).append(match.group(2))

            actual_keys = set(fields)
            if actual_keys != BOOTSTRAP_KEYS:
                errors.append(
                    f"{rel} must contain exactly the two bootstrap variables"
                )
            for field in sorted(BOOTSTRAP_KEYS & actual_keys):
                values = fields[field]
                if len(values) != 1 or not ENC_VALUE.fullmatch(values[0].strip()):
                    errors.append(f"{rel} has a plaintext or duplicate bootstrap variable")

config_recipients: set[str] = set()
config_text = texts.get(".sops.yaml")
if config_text is not None:
    config_recipients = set(AGE_RECIPIENT.findall(config_text))
    if len(config_recipients) != 2:
        errors.append(".sops.yaml must configure exactly two age recipients")

if secret_files and config_text is None:
    errors.append("encrypted SOPS files require a tracked .sops.yaml")

for rel, text in secret_files:
    file_recipients = set(AGE_RECIPIENT.findall(text))
    if config_recipients and file_recipients != config_recipients:
        errors.append(f"{rel} does not use both configured age recipients")

if errors:
    for error in dict.fromkeys(errors):
        print(f"SOPS contract violation: {error}", file=sys.stderr)
    sys.exit(1)

print(f"SOPS contract validation passed: {len(secret_files)} encrypted files checked")
PY
