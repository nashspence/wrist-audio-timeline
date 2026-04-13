# Devcontainer Notes

This devcontainer is configured for Docker outside of Docker.

That means the devcontainer does not run its own inner Docker daemon. Instead, it uses the host Docker daemon through the official `docker-outside-of-docker` dev container feature.

In this environment there is also an inner Docker daemon available at `/var/run/docker.sock`, but the intended default for `docker` and `docker compose` is the host daemon at `/run/docker-host.sock`.

## Workspace Path Mapping

Inside the devcontainer, this repository is mounted at:

- `/workspaces/services`

When you launch sibling containers with `docker run` from inside the devcontainer, those containers do not see `/workspaces/services` as a valid host path. They need the matching path on the host.

The recommended host-path mapping is exposed through:

- `LOCAL_WORKSPACE_FOLDER`

`LOCAL_WORKSPACE_FOLDER` is the host directory that corresponds to `/workspaces/services` inside the devcontainer.

Use it for bind mounts into sibling containers. Example:

```bash
docker run --rm \
  -v "${LOCAL_WORKSPACE_FOLDER}:/workspace:ro" \
  -w /workspace \
  python:3.12-slim \
  python -m py_compile schema.py
```
