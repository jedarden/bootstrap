#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the documented OS matrix in a disposable Debian container. The
# image supplies the required package tools; the systemctl shim models the
# command available on a normal systemd boot without starting systemd as PID 1.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${BOOTSTRAP_PLATFORM_TEST_IMAGE:-debian:12-slim}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-platform-acceptance.XXXXXX")

cleanup() {
    local exit_code=$?
    if [[ -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-platform-acceptance."* ]]; then
        rm -rf "$WORK"
    fi
    return "$exit_code"
}
trap cleanup EXIT

die() {
    echo "Bootstrap platform acceptance test failed: $*" >&2
    exit 1
}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    if [[ ${BOOTSTRAP_PLATFORM_TEST_REQUIRE_DOCKER:-false} == true ]]; then
        die 'a reachable Docker daemon is required'
    fi
    echo 'SKIP: bootstrap platform acceptance tests require a reachable Docker daemon' >&2
    exit 0
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Pulling disposable test image $IMAGE..."
    docker pull "$IMAGE" >/dev/null
fi

cat >"$WORK/systemctl" <<'SYSTEMCTL'
#!/bin/sh
exit 0
SYSTEMCTL
chmod 0755 "$WORK/systemctl"

run_case() {
    local label=$1 expected_status=$2 expected_text=$3
    local os_release="$WORK/$label-os-release"
    local output="$WORK/$label-output"
    shift 3
    printf '%s\n' "$@" >"$os_release"

    set +e
    docker run --rm \
        --volume "$ROOT/scripts/bootstrap-preflight.sh:/usr/local/sbin/bootstrap-preflight.sh:ro" \
        --volume "$os_release:/etc/os-release:ro" \
        --volume "$WORK/systemctl:/usr/local/bin/systemctl:ro" \
        "$IMAGE" /usr/local/sbin/bootstrap-preflight.sh >"$output" 2>&1
    local status=$?
    set -e

    [[ "$status" -eq "$expected_status" ]] || {
        echo "Unexpected status for $label: got $status, expected $expected_status" >&2
        cat "$output" >&2
        exit 1
    }
    grep -Fq "$expected_text" "$output" || {
        echo "Unexpected output for $label; missing: $expected_text" >&2
        cat "$output" >&2
        exit 1
    }
    echo "PASS: $label"
}

run_case debian-12 0 'Preflight passed: Debian 12 (bookworm)' \
    'NAME="Debian GNU/Linux"' \
    'ID=debian' \
    'VERSION_ID="12"' \
    'VERSION_CODENAME=bookworm' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case ubuntu-24.04 0 'Preflight passed: Ubuntu 24.04 (noble)' \
    'NAME="Ubuntu"' \
    'ID=ubuntu' \
    'VERSION_ID="24.04"' \
    'VERSION_CODENAME=noble' \
    'PRETTY_NAME="Ubuntu 24.04 LTS"'

run_case debian-13-unsupported 1 'unsupported release Debian GNU/Linux 13 (trixie)' \
    'NAME="Debian GNU/Linux"' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'VERSION_CODENAME=trixie' \
    'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"'

run_case alpine-unsupported 1 'unsupported operating system Alpine Linux v3.20' \
    'NAME="Alpine Linux"' \
    'ID=alpine' \
    'VERSION_ID="3.20"' \
    'PRETTY_NAME="Alpine Linux v3.20"'

run_case unknown-os 1 'could not identify the operating system' \
    'NAME="Unknown"' \
    'PRETTY_NAME="Unknown Linux"'

echo 'Bootstrap platform acceptance tests passed.'
