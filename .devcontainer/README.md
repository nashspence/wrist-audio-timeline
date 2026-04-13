# Devcontainer Notes

This devcontainer is configured for Docker outside of Docker.

That means the devcontainer does not run its own inner Docker daemon. Instead, it uses the host Docker daemon through the mounted `/var/run/docker.sock`.

## Workspace Path Mapping

Inside the devcontainer, this repository is mounted at:

- `/workspaces/services`

When you launch sibling containers with `docker run` from inside the devcontainer, those containers do not see `/workspaces/services` as a valid host path. They need the matching path on the host.

That host path is provided through:

- `DIND_HOST_DIRECTORY`

`DIND_HOST_DIRECTORY` is the host directory that corresponds to `/workspaces/services` inside the devcontainer.

Use it for bind mounts into sibling containers. Example:

```bash
docker run --rm \
  -v "${DIND_HOST_DIRECTORY}:/workspace:ro" \
  -w /workspace \
  python:3.12-slim \
  python -m py_compile schema.py
```

## Schema Validation

After rebuilding the devcontainer, run:

```bash
bash .devcontainer/test-schemas.sh
```

That script validates:

- the Pydantic schema in `schema.py`
- the PostgreSQL schema in `schema.sql`
- the Docker-outside-of-Docker bind-mount setup through `DIND_HOST_DIRECTORY`
