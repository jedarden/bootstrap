# Hetzner Robot provisioning

`robot.py` is a compatibility entry point for the dependency-free reconciler at
`k8s/hetzner-robot/robot.py`, which is mounted directly by the Kustomize base.
The implementation uses only Python's standard library.
It is intentionally limited to the boundary this repository can own:
activating a declared Linux installation and resetting the server so the
installer can run. The existing `hosts/ex44/bootstrap.sh` remains responsible
for configuring the installed operating system.

The Robot API uses a web-service username and password with HTTP Basic Auth.
Set them only through the environment; neither is accepted in the desired-state
file or printed in errors:

```sh
export HETZNER_ROBOT_USERNAME='web-service-user'
export HETZNER_ROBOT_PASSWORD='web-service-password'
python3 automation/hetzner_robot/robot.py reconcile \
  --config k8s/hetzner-robot/config.example.json \
  --state-file /tmp/hetzner-robot-state.json
```

The API URL must use HTTPS. `--allow-insecure-http` exists only for the local
HTTP server used by the API-level tests.

## Desired state

The configuration is JSON so it can be mounted directly as a ConfigMap:

```json
{
  "reset_after_change": true,
  "reinstall_on_drift": false,
  "servers": [
    {
      "server_number": 123456,
      "distribution": "Ubuntu 24.04",
      "language": "en",
      "authorized_keys": ["SHA256:operator-key-fingerprint"],
      "reset_type": "sw"
    }
  ]
}
```

An inactive server is activated once and then reset once. A matching active
configuration is a no-op. An active configuration that differs is reported as
drift and is not overwritten unless `reinstall_on_drift` is explicitly set to
`true`; changing a running server's OS is destructive. If Robot accepts an
activation but the reset fails, a small mode-0600 state file records the
pending reset and the next run retries only that reset.

The client retries transport failures and HTTP 408, 425, 429, and 5xx responses
with bounded exponential backoff. Authentication, validation, and other 4xx
errors fail immediately. API response bodies are never included in errors
because Robot can return generated root or rescue passwords.

## Kubernetes

The `k8s/hetzner-robot/` Kustomize base runs this program as a non-root,
single-replica Deployment with an internal hourly interval. It mounts the
program and JSON configuration from ConfigMaps, stores pending-operation state
on a small `sata` PVC, and expects an externally-managed Secret named
`hetzner-robot-credentials` with keys `username` and `password`. Use an
environment-specific GitOps overlay to replace the empty example server list
and provide that Secret through the cluster's normal secret-management workflow.
The base intentionally contains no credentials.

Run the API-level regression suite with:

```sh
tests/hetzner-robot-test.sh
```
