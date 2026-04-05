#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/docker-compose.rootless.yml"
ENV_ROOT_DEFAULT="${HOME}/.data/docker"
ENV_FILE_DEFAULT="${ENV_ROOT_DEFAULT}/paperclip.env"
ENV_FILE="${PAPERCLIP_DOCKER_ENV_FILE:-$ENV_FILE_DEFAULT}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is required." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Env file not found at $ENV_FILE" >&2
  echo "Nothing to stop." >&2
  exit 1
fi

docker compose \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_FILE" \
  down
