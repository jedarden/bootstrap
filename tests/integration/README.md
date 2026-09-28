# Bootstrap integration tests

Run the disposable-host integration and idempotence test with:

    tests/integration/bootstrap-test.sh

The runner starts a privileged, disposable Debian 12 container and a
privileged, disposable Ubuntu 24.04 container. In each image it runs the real
hosts/ex44/bootstrap.sh and checks the resulting SSH, UFW, sysctl, fail2ban,
auditd, user workspace, Tailscale, rootless Docker, restic/backup, and launcher
setup. It checks both default users (`coding` and `trading`), effective
security command output, unprivileged launcher and Docker-helper execution,
and cross-user read/write boundaries. The fixture verifies each image's
release, codename, and amd64 architecture before provisioning begins.

It then compares a normalized snapshot across a second bootstrap run, crosses a
simulated reboot boundary that clears volatile service and user-runtime state,
checks that enabled services and persisted workspaces recover, and runs the
bootstrap again. SSH, UFW, fail2ban, auditd, Tailscale, rootless Docker,
backup scheduling, user workspaces, and both launcher paths are checked both
after the reboot and after that post-reboot rerun. The per-user contract also
checks private home and SSH modes, user-owned executable launchers, PATH
resolution through `~/.local/bin/start`, and cross-user workspace read/write
denials. The snapshot ignores the timestamp in `/etc/bootstrap/config` so it
does not obscure convergence.

The credential-path runs also audit the live restic command argv and process
list, captured output for non-interactive sources, command logs, temporary
trees, and generated files. The SOPS, OpenBao, and interactive paths each
receive this audit, while
`tests/sops-environment-boundary-test.sh` separately exercises the
operator-to-bootstrap environment boundary. Together they verify that
SOPS age identities, ciphertext/input files, and OpenBao tokens never cross
the host boundary, that OpenBao's header file is mode `0600` and removed after
the read, and that SOPS/age are not installed as bootstrap runtime tools. The
runtime `/etc/restic/b2.env` destination is the only deliberate
secret-bearing file.

The container fixture provides deterministic doubles for package installation,
systemd-only operations, the reboot boundary, Tailscale enrollment, Docker,
and restic. Those
operations cannot safely or authentically run against the test runner's host
or a test account. The test still exercises the production script's control
flow and inspects the files, permissions, service configuration, command
paths, and state it produces. It intentionally does not call --verify; that
is a separate read-only production check.

Requirements: Docker with permission to run privileged containers and network
access to pull `debian:12-slim` and `ubuntu:24.04` plus the distribution package
mirror used to install OpenSSL in minimal images. If Docker is not reachable,
the test reports `SKIP` so host-independent definition-of-done checks remain
usable; set `BOOTSTRAP_TEST_REQUIRE_DOCKER=true` to make that environment a
failure. Use `--keep` while diagnosing a failed disposable host.
`BOOTSTRAP_TEST_DEBIAN_IMAGE` and `BOOTSTRAP_TEST_UBUNTU_IMAGE` override the
two images independently.

## Clean-host disaster recovery

Run the single-host rebuild drill with:

    tests/integration/disaster-recovery-test.sh

This drill authenticates the published EX44 archive with the pinned signing
key, manifest signature, SHA-256 entries, and current/archive equality before
creating a host. It then creates disposable SOPS ciphertext for both
bootstrap secrets, removes the primary age identity, and uses only the
mode-0600 recovery identity through `sops exec-env`. The target receives no
SOPS binary, age identity, or ciphertext file.

The clean Debian 12 host is seeded with a representative surviving B2/restic
snapshot. The verified bootstrap restores `/home` and `/var/lib/tailscale`,
then the drill checks the restored marker, user ownership, Tailscale/SSH
access, the unprivileged launcher, private restic configuration, and the
read-only bootstrap verification summary. A simulated reboot clears volatile
service state and the same access, launcher, restored-data, and verification
checks run again.

The test uses the same `tests/integration/host-fixture.sh` doubles as the
matrix test, so it never contacts a real B2 account or writes operator
credentials to a host. Set `BOOTSTRAP_RECOVERY_TEST_REQUIRE_DOCKER=true` (and
`BOOTSTRAP_RECOVERY_TEST_REQUIRE_TOOLS=true`) to make missing Docker or
operator SOPS/age tools a failure instead of a skip. Override the image with
`BOOTSTRAP_RECOVERY_TEST_IMAGE`; it must remain a Debian 12 amd64 image.
