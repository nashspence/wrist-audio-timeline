#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${ROOT_DIR}"

if [[ ! -f .env && -f .env.example ]]; then
  cp .env.example .env
fi

if [[ -f requirements-dev.txt ]]; then
  uv pip install --system -r requirements-dev.txt
fi

if [[ -n "${LOCAL_WORKSPACE_FOLDER:-}" ]]; then
  echo "Docker outside of Docker is enabled."
  echo "Host path for ${ROOT_DIR} in sibling containers: ${LOCAL_WORKSPACE_FOLDER}"
fi
