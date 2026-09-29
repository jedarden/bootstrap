#!/usr/bin/env bash
set -Eeuo pipefail

# Check the operator runbooks against the repository's current files and
# command interfaces.  The implementation lives in Python so shell examples
# can be tokenized without ever being executed.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
    cat <<'USAGE'
Usage: scripts/check-documentation.sh [--root PATH]

Check release, security, and SOPS runbooks for broken links, stale repository
paths, removed scripts, and options or commands that no longer exist.

--root PATH  Check a repository copy at PATH instead of this checkout.
USAGE
}

while (($# > 0)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            ROOT=$2
            shift 2
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
done

ROOT=$(cd "$ROOT" && pwd)
export DOCUMENTATION_CHECK_ROOT="$ROOT"

python3 - <<'PY'
from __future__ import annotations

import glob
import os
import pathlib
import re
import shlex
import subprocess
import sys
from collections import defaultdict


root = pathlib.Path(os.environ["DOCUMENTATION_CHECK_ROOT"])
errors: list[str] = []

RUNBOOKS = [
    pathlib.Path("docs/release-rollout.md"),
    pathlib.Path("docs/secrets/sops.md"),
    *sorted(pathlib.Path("docs/security").glob("*.md")),
]

# These are the repository commands whose interfaces are part of the operator
# contract.  Test programs are checked for existence and executability, but
# their fixture arguments are deliberately not treated as a public CLI.
COMMANDS = {
    pathlib.Path("scripts/start-sh-release.sh"): {
        "commands": {
            "release",
            "rollback",
            "manifest",
            "rotation-check",
            "distribution-check",
            "verify-distribution",
            "publish",
        },
        "value_options": {"--host"},
    },
    pathlib.Path("scripts/check-host-parity.sh"): {
        "commands": set(),
        "value_options": set(),
    },
    pathlib.Path("scripts/check-rollout-targets.sh"): {
        "commands": set(),
        "value_options": set(),
    },
    pathlib.Path("scripts/check-secret-leakage.sh"): {
        "commands": set(),
        "value_options": {"--path"},
    },
    pathlib.Path("scripts/check-sops-contract.sh"): {
        "commands": set(),
        "value_options": {"--root"},
    },
    pathlib.Path("scripts/bootstrap-preflight.sh"): {
        "commands": set(),
        "value_options": {"--os-release"},
    },
    pathlib.Path("scripts/verify-deployed-launchers.sh"): {
        "commands": set(),
        "value_options": set(),
    },
    pathlib.Path("scripts/definition-of-done.sh"): {
        "commands": set(),
        "value_options": set(),
    },
    pathlib.Path("ansible/run-drift.sh"): {
        "commands": {"check", "apply"},
        "value_options": set(),
        "passthrough": True,
    },
    pathlib.Path("hosts/ex44/sync-start-sh.sh"): {
        "commands": set(),
        "value_options": set(),
    },
    pathlib.Path("hosts/ex44/start.sh"): {
        "commands": set(),
        "value_options": {"--agent"},
    },
    pathlib.Path("hosts/ex44/bootstrap.sh"): {
        "commands": set(),
        "value_options": set(),
    },
}

SCRIPT_PATH = re.compile(
    r"(?<![A-Za-z0-9_./-])"
    r"(?P<path>(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)?"
    r"(?:\./)?(?:scripts|tests|ansible|hosts)/"
    r"[A-Za-z0-9_./${}*<>:-]+\.sh|"
    r"(?:\./)?sync-start-sh\.sh)"
)
KNOWN_PATH = re.compile(
    r"(?<![A-Za-z0-9_./-])"
    r"(?P<path>(?:\.\.?/)*(?:scripts|tests|ansible|hosts|docs)/"
    r"[A-Za-z0-9_./${}*<>:-]+|"
    r"(?:\.\.?/)*(?:README\.md|\.gitignore|\.sops\.yaml(?:\.example)?|"
    r"sops\.yaml\.example))"
)
MARKDOWN_LINK = re.compile(r"!?\[[^]]*\]\(([^)]+)\)")
OPTION = re.compile(r"(?<![A-Za-z0-9_])(--[A-Za-z][A-Za-z0-9-]*|-[hv])(?:=\S+)?")
HEADING = re.compile(r"^#{1,6}\s+(.+?)\s*#*\s*$")


def rel(path: pathlib.Path) -> str:
    return path.relative_to(root).as_posix()


def error(path: pathlib.Path, line: int, message: str) -> None:
    errors.append(f"{rel(path)}:{line}: {message}")


def read(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        error(path, 1, f"cannot read UTF-8 documentation: {exc}")
        return ""


def github_slug(value: str) -> str:
    value = re.sub(r"[`*_~]", "", value)
    value = re.sub(r"\[[^]]*\]\([^)]*\)", "", value)
    value = value.lower()
    value = re.sub(r"[^\w\s-]", "", value)
    return re.sub(r"[-\s]+", "-", value).strip("-")


def heading_anchors(text: str) -> set[str]:
    anchors: set[str] = set()
    counts: defaultdict[str, int] = defaultdict(int)
    for line in text.splitlines():
        match = HEADING.match(line)
        if not match:
            continue
        base = github_slug(match.group(1))
        number = counts[base]
        counts[base] += 1
        anchors.add(base if number == 0 else f"{base}-{number}")
    return anchors


def substitute_path(value: str) -> str:
    value = value.strip().strip("`\"'<>(),;:")
    value = value.replace('"', "").replace("'", "")
    value = re.sub(r"\$\{(?:repo|ROOT)\}/?", "", value)
    value = re.sub(r"\$(?:repo|ROOT)/?", "", value)
    value = re.sub(r"\$\{(?:host|lineage|source_host)\}", "ex44", value)
    value = re.sub(r"\$(?:host|lineage|source_host)", "ex44", value)
    value = re.sub(r"\$\{(?:slot)\}", "jeda-mbp", value)
    value = re.sub(r"\$(?:slot)", "jeda-mbp", value)
    value = re.sub(r"\$\{[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*", "*", value)
    value = value.replace("<host>", "ex44").replace("<lineage>", "ex44")
    value = value.replace("<version>", "*")
    return value


def candidate_path(raw: str, document: pathlib.Path) -> tuple[str, pathlib.Path] | None:
    raw = substitute_path(raw)
    if not raw or raw.startswith(("http:", "https:", "mailto:", "/", "#")):
        return None

    # ./scripts/... and ./tests/... are commands run from the repository root.
    if raw == "sops.yaml.example":
        path = root / document.parent / raw
    elif raw.startswith(("./scripts/", "./tests/", "./ansible/", "./hosts/", "./docs/")):
        raw = raw[2:]
        path = root / raw
    elif raw.startswith(("../", "../../")):
        path = (root / document.parent / raw).resolve()
    elif raw.startswith("./"):
        path = (root / document.parent / raw[2:]).resolve()
    elif raw.startswith(("scripts/", "tests/", "ansible/", "hosts/", "docs/", "README.md", ".gitignore", ".sops.yaml", "sops.yaml.example")):
        path = root / raw
    else:
        return None

    return raw, path


def validate_path(raw: str, document: pathlib.Path, line: int, *, link: bool = False) -> None:
    result = candidate_path(raw, document)
    if result is None:
        return
    normalized, path = result

    # These are deliberately absent from a normal checkout: .sops.yaml and
    # ansible/group_vars are operator-created/ignored locations, while the
    # angle-bracket paths are runbook templates rather than literal files.
    if normalized == ".sops.yaml" or normalized.startswith("ansible/group_vars"):
        return
    if "<" in normalized or ">" in normalized:
        return
    # A shell variable in a quoted archive name can leave the path scanner
    # with only the literal prefix (for example bootstrap-"$VERSION".sh).
    if normalized.endswith("-"):
        return

    # Secrets are intentionally optional, ignored runtime inputs. The
    # repository docs describe their names, but a clean checkout need not
    # contain ciphertext for every host.
    if normalized.startswith("secrets/"):
        return

    if "*" in normalized:
        matches = glob.glob(str(path))
        if matches:
            return
    elif path.exists():
        return

    # The onboarding guide intentionally uses hosts/lab as a future example.
    # All other host paths, including dynamic $host paths substituted to ex44,
    # must resolve in the checkout.
    if normalized.startswith("hosts/lab"):
        return

    kind = "link target" if link else "repository path"
    error(document, line, f"{kind} does not exist: {raw}")


def parse_fenced_commands(lines: list[str]) -> list[tuple[int, str]]:
    commands: list[tuple[int, str]] = []
    in_bash = False
    pending = ""
    pending_line = 0
    fence = None

    for number, line in enumerate(lines, 1):
        marker = re.match(r"^\s*(```|~~~)([A-Za-z0-9_-]*)\s*$", line)
        if marker:
            if not in_bash:
                in_bash = marker.group(2).lower() in {"bash", "sh", "shell"}
                fence = marker.group(1)
            elif marker.group(1) == fence:
                in_bash = False
                fence = None
                pending = ""
            continue
        if not in_bash:
            continue

        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not pending:
            pending_line = number
        pending += (" " if pending else "") + stripped
        if pending.endswith("\\"):
            pending = pending[:-1].rstrip()
            continue
        commands.append((pending_line, pending))
        pending = ""

    if pending:
        commands.append((pending_line, pending))
    return commands


def option_set(path: pathlib.Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    return {match.group(1) for match in OPTION.finditer(text)}


def script_for_path(raw: str) -> pathlib.Path | None:
    normalized = substitute_path(raw).lstrip("./")
    if normalized.startswith("sync-start-sh.sh"):
        return pathlib.Path("hosts/ex44/sync-start-sh.sh")
    if normalized.startswith("scripts/") or normalized.startswith("tests/") or normalized.startswith("ansible/") or normalized.startswith("hosts/"):
        path = pathlib.PurePosixPath(normalized)
        if "*" in normalized or "<" in normalized or "$" in normalized:
            return None
        if path.parts[-1] == "sync-start-sh.sh":
            return pathlib.Path("hosts/ex44/sync-start-sh.sh")
        if path.parts[0] == "hosts" and len(path.parts) >= 3 and path.parts[2] in {"start.sh", "bootstrap.sh"}:
            return pathlib.Path("hosts/ex44") / path.parts[2]
        return pathlib.Path(path)
    return None


def validate_invocation(document: pathlib.Path, line: int, raw_path: str, command_line: str) -> None:
    script = script_for_path(raw_path)
    if script is None:
        return
    full_path = root / script
    if not full_path.is_file():
        error(document, line, f"documented script does not exist: {raw_path}")
        return
    if not os.access(full_path, os.X_OK):
        error(document, line, f"documented script is not executable: {script.as_posix()}")

    interface = COMMANDS.get(script)
    if interface is None or script.parts[0] == "tests":
        return

    if interface.get("passthrough"):
        try:
            tokens = shlex.split(command_line[command_line.find(raw_path) :])
        except ValueError:
            return
        if len(tokens) > 1 and tokens[1] not in interface["commands"]:
            error(document, line, f"{script.as_posix()} does not accept documented command {tokens[1]}")
        return

    options = option_set(full_path)
    for match in OPTION.finditer(command_line[command_line.find(raw_path) :]):
        option = match.group(1)
        if option not in options:
            error(document, line, f"{script.as_posix()} does not accept documented option {option}")

    try:
        tokens = shlex.split(command_line[command_line.find(raw_path) :])
    except ValueError:
        return
    args = tokens[1:]
    positional: list[str] = []
    index = 0
    while index < len(args):
        token = args[index]
        if token == "--":
            positional.extend(args[index + 1 :])
            break
        if token.startswith("--"):
            option = token.split("=", 1)[0]
            if option in interface["value_options"] and "=" not in token:
                index += 1
            index += 1
            continue
        if token.startswith("-"):
            index += 1
            continue
        positional.append(token)
        index += 1

    if interface["commands"] and positional and positional[0] not in interface["commands"]:
        error(document, line, f"{script.as_posix()} does not accept documented command {positional[0]}")
    elif not interface["commands"] and positional:
        error(document, line, f"{script.as_posix()} does not accept documented argument {positional[0]}")


def validate_document(document: pathlib.Path) -> tuple[int, int]:
    text = read(document)
    lines = text.splitlines()
    anchors = heading_anchors(text)
    path_count = 0
    command_count = 0

    for line_number, line in enumerate(lines, 1):
        for match in MARKDOWN_LINK.finditer(line):
            target = match.group(1).strip().strip("<>")
            if target.startswith(("http:", "https:", "mailto:")):
                continue
            target_path, separator, fragment = target.partition("#")
            if target_path:
                validate_path(target_path, document, line_number, link=True)
                path_count += 1
                if target_path.startswith("#"):
                    fragment = target_path[1:]
            if fragment:
                if target_path:
                    destination = candidate_path(target_path, document)
                    destination_path = destination[1] if destination else None
                else:
                    destination_path = document
                if destination_path and destination_path.is_file():
                    destination_text = read(destination_path)
                    if fragment.lower() not in heading_anchors(destination_text):
                        error(document, line_number, f"link anchor does not exist: {target}")

        for match in KNOWN_PATH.finditer(line):
            validate_path(match.group("path"), document, line_number)
            path_count += 1

    for line_number, command_line in parse_fenced_commands(lines):
        for match in SCRIPT_PATH.finditer(command_line):
            # A path passed to git add, bash -n, cp, or another command is a
            # file reference, not an invocation whose CLI needs checking.
            prefix = command_line[: match.start()].rstrip()
            separators = [prefix.rfind(token) for token in ("&&", "||", ";", "|", "(")]
            segment = prefix[max(separators, default=-1) + 1 :].strip()
            if segment and not re.fullmatch(r"(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s*)+", segment):
                continue
            validate_invocation(document, line_number, match.group("path"), command_line)
            command_count += 1

        # The deployed launcher and bootstrap archives are also operational
        # interfaces in the runbooks, even when their path is a host's $HOME
        # or a downloaded /root archive rather than a repository path.
        if re.search(r"(?:^|\s)(?:git|cp|install|mv|grep|sed)\s", command_line):
            continue
        for launcher in re.finditer(r"(?<![A-Za-z0-9_-])(?:start\.sh|bootstrap(?:-[0-9][^\s/\"']*)?\.sh)", command_line):
            raw = launcher.group(0)
            if raw.startswith("bootstrap"):
                validate_invocation(document, line_number, "hosts/ex44/bootstrap.sh", command_line)
            else:
                validate_invocation(document, line_number, "hosts/ex44/start.sh", command_line)

    return path_count, command_count


missing_runbooks = [path for path in RUNBOOKS if not (root / path).is_file()]
for path in missing_runbooks:
    errors.append(f"{path.as_posix()}:1: required runbook is missing")

total_paths = 0
total_commands = 0
for path in RUNBOOKS:
    if (root / path).is_file():
        paths, commands = validate_document(root / path)
        total_paths += paths
        total_commands += commands

if errors:
    for message in dict.fromkeys(errors):
        print(f"Documentation reference violation: {message}", file=sys.stderr)
    sys.exit(1)

print(
    f"Documentation reference validation passed: {len(RUNBOOKS)} runbooks, "
    f"{total_paths} paths, {total_commands} script commands checked"
)
PY
