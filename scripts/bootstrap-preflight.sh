#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the host contract before running hosts/ex44/bootstrap.sh.
#
# The bootstrap artifacts are signed and immutable. Keep this check separate
# from them so an operator can validate a freshly installed host without
# changing the release artifact or its signature.

SUPPORTED_ARCHITECTURE="amd64"
OS_RELEASE_FILE="/etc/os-release"

usage() {
    cat <<'USAGE'
Usage: scripts/bootstrap-preflight.sh [--os-release FILE]

Validate the supported EX44 bootstrap host contract without changing the
host. --os-release is intended for image and acceptance-test fixtures.
USAGE
}

fail() {
    echo "ERROR: preflight failed: $*" >&2
    exit 1
}

read_os_release_value() {
    local key=$1 path=$2 value

    value=$(sed -n "s/^${key}=//p" "$path" | head -n 1)
    value=${value#\"}
    value=${value%\"}
    value=${value#\'}
    value=${value%\'}
    printf '%s' "$value"
}

while (($# > 0)); do
    case "$1" in
        --os-release)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            OS_RELEASE_FILE=$2
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

[[ $EUID -eq 0 ]] || fail "run as root (use sudo)"
[[ -r "$OS_RELEASE_FILE" ]] || fail "cannot read $OS_RELEASE_FILE; refusing to guess the operating system"

os_id=$(read_os_release_value ID "$OS_RELEASE_FILE")
version_id=$(read_os_release_value VERSION_ID "$OS_RELEASE_FILE")
pretty_name=$(read_os_release_value PRETTY_NAME "$OS_RELEASE_FILE")

[[ -n "$os_id" && -n "$version_id" ]] ||
    fail "could not identify the operating system from $OS_RELEASE_FILE (ID and VERSION_ID are required)"

case "$os_id:$version_id" in
    debian:12)
        supported_release="Debian 12 (bookworm)"
        ;;
    ubuntu:24.04)
        supported_release="Ubuntu 24.04 (noble)"
        ;;
    debian:*|ubuntu:*)
        fail "unsupported release ${pretty_name:-$os_id $version_id}; supported releases are Debian 12 (bookworm) and Ubuntu 24.04 (noble)"
        ;;
    *)
        fail "unsupported operating system ${pretty_name:-$os_id $version_id}; only Debian 12 (bookworm) and Ubuntu 24.04 (noble) are supported"
        ;;
esac

for required_command in bash apt-get dpkg systemctl getent; do
    command -v "$required_command" >/dev/null 2>&1 ||
        fail "required command '$required_command' is missing; install it in the base image before bootstrap"
done

architecture=$(dpkg --print-architecture 2>/dev/null) ||
    fail "could not determine the dpkg architecture"
[[ "$architecture" == "$SUPPORTED_ARCHITECTURE" ]] ||
    fail "unsupported architecture '$architecture'; EX44 bootstrap supports $SUPPORTED_ARCHITECTURE only"

echo "Preflight passed: $supported_release on $architecture."
echo "Assumptions remaining for bootstrap: root, an interactive terminal, systemd as PID 1, and working DNS/HTTPS access."
