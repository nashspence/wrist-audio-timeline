#!/usr/bin/env bash
set -euo pipefail

cd /workspaces/services

if [[ ! -f .env && -f .env.example ]]; then
  cp .env.example .env
fi

if [[ -f requirements-dev.txt ]]; then
  uv pip install --system -r requirements-dev.txt
fi

if [[ -f .devcontainer/test-schemas.sh ]]; then
  chmod +x .devcontainer/test-schemas.sh
fi

if [[ -n "${DIND_HOST_DIRECTORY:-}" ]]; then
  echo "Docker outside of Docker is enabled."
  echo "Host path for /workspaces/services in sibling containers: ${DIND_HOST_DIRECTORY}"
fi
