# Bootstrap integration tests

Run the disposable-host integration and idempotence test with:

    tests/integration/bootstrap-test.sh

The runner starts a privileged, disposable Debian container, runs the real
hosts/ex44/bootstrap.sh, and checks the resulting SSH, UFW, sysctl, fail2ban,
auditd, user workspace, Tailscale, rootless Docker, restic/backup, and launcher
setup. It checks both default users (`coding` and `trading`), effective
security command output, unprivileged launcher and Docker-helper execution,
and cross-user read/write boundaries.

It then compares a normalized snapshot across a second bootstrap run, crosses a
simulated reboot boundary that clears volatile service and user-runtime state,
checks that enabled services and persisted workspaces recover, and runs the
bootstrap again. SSH, UFW, fail2ban, auditd, Tailscale, rootless Docker,
backup scheduling, user workspaces, and both launcher paths are checked both
after the reboot and after that post-reboot rerun. The snapshot ignores the
timestamp in `/etc/bootstrap/config` so it does not obscure convergence.

The credential-path runs also audit the live restic command argv and process
list, captured output for non-interactive sources, command logs, temporary
trees, and generated files. The SOPS, OpenBao, and interactive paths each
receive this audit; OpenBao's header file is checked at mode `0600` and
after-read removal, while the runtime `/etc/restic/b2.env` destination is the
only deliberate secret-bearing file.

The container fixture provides deterministic doubles for package installation,
systemd-only operations, the reboot boundary, Tailscale enrollment, Docker,
and restic. Those
operations cannot safely or authentically run against the test runner's host
or a test account. The test still exercises the production script's control
flow and inspects the files, permissions, service configuration, command
paths, and state it produces. It intentionally does not call --verify; that
is a separate read-only production check.

Requirements: Docker with permission to run privileged containers and network
access to pull debian:12-slim when it is not already cached. If Docker is not
reachable, the test reports `SKIP` so host-independent definition-of-done
checks remain usable; set `BOOTSTRAP_TEST_REQUIRE_DOCKER=true` to make that
environment a failure. Use --keep while diagnosing a failed disposable host.
