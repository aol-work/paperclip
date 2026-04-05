#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker/docker-compose.rootless.yml"
IMAGE_NAME="paperclip-rootless:local"
ENV_ROOT_DEFAULT="${HOME}/.data/docker"
ENV_FILE_DEFAULT="${ENV_ROOT_DEFAULT}/paperclip.env"
TMP_DIR=""
COOKIE_JAR=""
FORCE_BUILD="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      FORCE_BUILD="true"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--build]" >&2
      exit 1
      ;;
  esac
done

rand_hex() {
  local bytes="${1:-32}"
  head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

read_env_value() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" | tail -n 1 | cut -d= -f2- || true
}

url_origin() {
  printf '%s\n' "$1" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://[^/]+).*$#\1#'
}

url_hostname() {
  printf '%s\n' "$1" \
    | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##' \
    | sed -E 's#/.*$##' \
    | sed -E 's#^\[([^]]+)\](:.*)?$#\1#' \
    | sed -E 's#:.*$##'
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

read_openai_api_key() {
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    printf '%s\n' "$OPENAI_API_KEY"
    return 0
  fi

  if ! command -v pass >/dev/null 2>&1; then
    return 0
  fi

  pass api_keys/openai/paperclip 2>/dev/null | head -n 1 || true
}

image_exists() {
  docker image inspect "$IMAGE_NAME" >/dev/null 2>&1
}

should_build_image() {
  if [[ "$FORCE_BUILD" == "true" ]]; then
    return 0
  fi

  ! image_exists
}

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT

require_cmd docker
require_cmd curl

if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is required." >&2
  exit 1
fi

ENV_ROOT="${PAPERCLIP_DOCKER_ROOT:-$(read_env_value "${PAPERCLIP_DOCKER_ENV_FILE:-$ENV_FILE_DEFAULT}" PAPERCLIP_DOCKER_ROOT)}"
ENV_ROOT="${ENV_ROOT:-$ENV_ROOT_DEFAULT}"
ENV_FILE="${PAPERCLIP_DOCKER_ENV_FILE:-$ENV_ROOT/paperclip.env}"
PAPERCLIP_PORT="${PAPERCLIP_PORT:-$(read_env_value "$ENV_FILE" PAPERCLIP_PORT)}"
PAPERCLIP_DATA_VOLUME="${PAPERCLIP_DATA_VOLUME:-$(read_env_value "$ENV_FILE" PAPERCLIP_DATA_VOLUME)}"
PAPERCLIP_WORKSPACE_VOLUME="${PAPERCLIP_WORKSPACE_VOLUME:-$(read_env_value "$ENV_FILE" PAPERCLIP_WORKSPACE_VOLUME)}"
PAPERCLIP_PORT="${PAPERCLIP_PORT:-3100}"
PAPERCLIP_DATA_VOLUME="${PAPERCLIP_DATA_VOLUME:-paperclip-data}"
PAPERCLIP_WORKSPACE_VOLUME="${PAPERCLIP_WORKSPACE_VOLUME:-paperclip-workspace}"

mkdir -p "$ENV_ROOT"

PAPERCLIP_PUBLIC_URL="${PAPERCLIP_PUBLIC_URL:-$(read_env_value "$ENV_FILE" PAPERCLIP_PUBLIC_URL)}"
PAPERCLIP_PUBLIC_URL="${PAPERCLIP_PUBLIC_URL:-http://localhost:${PAPERCLIP_PORT}}"
BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-$(read_env_value "$ENV_FILE" BETTER_AUTH_SECRET)}"
BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-$(rand_hex 32)}"
BETTER_AUTH_URL="${BETTER_AUTH_URL:-$(read_env_value "$ENV_FILE" BETTER_AUTH_URL)}"
BETTER_AUTH_URL="${BETTER_AUTH_URL:-$PAPERCLIP_PUBLIC_URL}"
BETTER_AUTH_BASE_URL="${BETTER_AUTH_BASE_URL:-$(read_env_value "$ENV_FILE" BETTER_AUTH_BASE_URL)}"
BETTER_AUTH_BASE_URL="${BETTER_AUTH_BASE_URL:-$PAPERCLIP_PUBLIC_URL}"
OPENAI_API_KEY="$(read_openai_api_key)"
export OPENAI_API_KEY

PUBLIC_ORIGIN="$(url_origin "$PAPERCLIP_PUBLIC_URL")"
PUBLIC_HOSTNAME="$(url_hostname "$PAPERCLIP_PUBLIC_URL")"
if [[ -z "$PUBLIC_ORIGIN" || -z "$PUBLIC_HOSTNAME" ]]; then
  echo "Could not derive origin/hostname from PAPERCLIP_PUBLIC_URL=$PAPERCLIP_PUBLIC_URL" >&2
  exit 1
fi

BETTER_AUTH_TRUSTED_ORIGINS="${BETTER_AUTH_TRUSTED_ORIGINS:-$(read_env_value "$ENV_FILE" BETTER_AUTH_TRUSTED_ORIGINS)}"
BETTER_AUTH_TRUSTED_ORIGINS="${BETTER_AUTH_TRUSTED_ORIGINS:-$PUBLIC_ORIGIN}"
PAPERCLIP_ALLOWED_HOSTNAMES="${PAPERCLIP_ALLOWED_HOSTNAMES:-$(read_env_value "$ENV_FILE" PAPERCLIP_ALLOWED_HOSTNAMES)}"
PAPERCLIP_ALLOWED_HOSTNAMES="${PAPERCLIP_ALLOWED_HOSTNAMES:-$PUBLIC_HOSTNAME}"

PAPERCLIP_BOOTSTRAP_ADMIN_NAME="${PAPERCLIP_BOOTSTRAP_ADMIN_NAME:-$(read_env_value "$ENV_FILE" PAPERCLIP_BOOTSTRAP_ADMIN_NAME)}"
PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL="${PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL:-$(read_env_value "$ENV_FILE" PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL)}"
PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD="${PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD:-$(read_env_value "$ENV_FILE" PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD)}"
PAPERCLIP_BOOTSTRAP_ADMIN_NAME="${PAPERCLIP_BOOTSTRAP_ADMIN_NAME:-paperclip-admin}"
PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL="${PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL:-admin@paperclip.local}"
PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD="${PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD:-pc-$(rand_hex 12)}"

USER_UID="$(id -u)"
USER_GID="$(id -g)"

cat >"$ENV_FILE" <<EOF
PAPERCLIP_DOCKER_ROOT=$ENV_ROOT
PAPERCLIP_DATA_VOLUME=$PAPERCLIP_DATA_VOLUME
PAPERCLIP_WORKSPACE_VOLUME=$PAPERCLIP_WORKSPACE_VOLUME
PAPERCLIP_PORT=$PAPERCLIP_PORT
PAPERCLIP_PUBLIC_URL=$PAPERCLIP_PUBLIC_URL
PAPERCLIP_ALLOWED_HOSTNAMES=$PAPERCLIP_ALLOWED_HOSTNAMES
BETTER_AUTH_SECRET=$BETTER_AUTH_SECRET
BETTER_AUTH_URL=$BETTER_AUTH_URL
BETTER_AUTH_BASE_URL=$BETTER_AUTH_BASE_URL
BETTER_AUTH_TRUSTED_ORIGINS=$BETTER_AUTH_TRUSTED_ORIGINS
PAPERCLIP_BOOTSTRAP_ADMIN_NAME=$PAPERCLIP_BOOTSTRAP_ADMIN_NAME
PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL=$PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL
PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD=$PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD
USER_UID=$USER_UID
USER_GID=$USER_GID
EOF
chmod 600 "$ENV_FILE"

wait_for_http() {
  local url="$1"
  local attempts="${2:-120}"
  local sleep_seconds="${3:-1}"
  local i
  for ((i = 1; i <= attempts; i += 1)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

post_json_with_cookies() {
  local url="$1"
  local body="$2"
  local output_file="$3"
  curl -sS \
    -o "$output_file" \
    -w "%{http_code}" \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    -H "Content-Type: application/json" \
    -H "Origin: $PAPERCLIP_PUBLIC_URL" \
    -X POST \
    "$url" \
    --data "$body"
}

get_with_cookies() {
  local url="$1"
  curl -fsS \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    -H "Accept: application/json" \
    "$url"
}

generate_bootstrap_invite_url() {
  local bootstrap_output
  local bootstrap_status
  if bootstrap_output="$(
    docker exec \
      -e PAPERCLIP_PUBLIC_URL="$PAPERCLIP_PUBLIC_URL" \
      -e PAPERCLIP_HOME="/paperclip" \
      paperclip-rootless bash -lc \
      'timeout 20s node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo --data-dir "$PAPERCLIP_HOME" --base-url "$PAPERCLIP_PUBLIC_URL"' \
      2>&1
  )"; then
    bootstrap_status=0
  else
    bootstrap_status=$?
  fi

  if [[ $bootstrap_status -ne 0 && $bootstrap_status -ne 124 ]]; then
    echo "Could not create bootstrap invite inside the container." >&2
    printf '%s\n' "$bootstrap_output" >&2
    return 1
  fi

  local invite_url
  invite_url="$(
    printf '%s\n' "$bootstrap_output" \
      | grep -o 'https\?://[^[:space:]]*/invite/pcp_bootstrap_[[:alnum:]]*' \
      | tail -n 1
  )"

  if [[ -z "$invite_url" ]]; then
    echo "Bootstrap invite command did not print an invite URL." >&2
    printf '%s\n' "$bootstrap_output" >&2
    return 1
  fi

  printf '%s\n' "$invite_url"
}

sign_up_or_sign_in() {
  local signup_response="$TMP_DIR/signup.json"
  local signup_status
  signup_status="$(post_json_with_cookies \
    "$PAPERCLIP_PUBLIC_URL/api/auth/sign-up/email" \
    "{\"name\":\"$PAPERCLIP_BOOTSTRAP_ADMIN_NAME\",\"email\":\"$PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL\",\"password\":\"$PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD\"}" \
    "$signup_response")"
  if [[ "$signup_status" =~ ^2 ]]; then
    return 0
  fi

  local signin_response="$TMP_DIR/signin.json"
  local signin_status
  signin_status="$(post_json_with_cookies \
    "$PAPERCLIP_PUBLIC_URL/api/auth/sign-in/email" \
    "{\"email\":\"$PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL\",\"password\":\"$PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD\"}" \
    "$signin_response")"
  if [[ "$signin_status" =~ ^2 ]]; then
    return 0
  fi

  echo "Could not sign up or sign in the bootstrap admin user." >&2
  cat "$signup_response" >&2 || true
  echo >&2
  cat "$signin_response" >&2 || true
  echo >&2
  return 1
}

bootstrap_admin_if_needed() {
  local health_json="$1"

  if [[ "$health_json" != *'"deploymentMode":"authenticated"'* ]]; then
    return 0
  fi

  if [[ "$health_json" == *'"bootstrapStatus":"ready"'* ]]; then
    return 0
  fi

  sign_up_or_sign_in

  local invite_url
  invite_url="$(generate_bootstrap_invite_url)"
  local invite_token="${invite_url##*/}"
  local accept_response="$TMP_DIR/accept.json"
  local accept_status
  accept_status="$(post_json_with_cookies \
    "$PAPERCLIP_PUBLIC_URL/api/invites/$invite_token/accept" \
    '{"requestType":"human"}' \
    "$accept_response")"
  if [[ ! "$accept_status" =~ ^2 ]]; then
    echo "Bootstrap invite acceptance failed with HTTP $accept_status." >&2
    cat "$accept_response" >&2 || true
    echo >&2
    return 1
  fi

  local session_json
  session_json="$(get_with_cookies "$PAPERCLIP_PUBLIC_URL/api/auth/get-session")"
  if [[ "$session_json" != *'"userId"'* ]]; then
    echo "Bootstrap finished but no authenticated session was created." >&2
    echo "$session_json" >&2
    return 1
  fi
}

echo "Starting Paperclip with:"
echo "  data volume: $PAPERCLIP_DATA_VOLUME"
echo "  workspace volume: $PAPERCLIP_WORKSPACE_VOLUME"
echo "  public url: $PAPERCLIP_PUBLIC_URL"
echo "  env file: $ENV_FILE"
if [[ -n "$OPENAI_API_KEY" ]]; then
  echo "  OPENAI_API_KEY: forwarded"
else
  echo "  OPENAI_API_KEY: not set"
fi
if should_build_image; then
  if [[ "$FORCE_BUILD" == "true" ]]; then
    echo "  build: forced"
  else
    echo "  build: image missing"
  fi
  docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    build
else
  echo "  build: skipped"
fi

docker compose \
  --env-file "$ENV_FILE" \
  -f "$COMPOSE_FILE" \
  up -d

if ! wait_for_http "$PAPERCLIP_PUBLIC_URL/api/health" 180 1; then
  echo "Paperclip did not become ready at $PAPERCLIP_PUBLIC_URL/api/health" >&2
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --tail=200 >&2 || true
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/paperclip-docker-start.XXXXXX")"
COOKIE_JAR="$TMP_DIR/cookies.txt"
HEALTH_JSON="$(curl -fsS "$PAPERCLIP_PUBLIC_URL/api/health")"
bootstrap_admin_if_needed "$HEALTH_JSON"

echo
echo "Paperclip is ready."
echo "  URL: $PAPERCLIP_PUBLIC_URL"
echo "  Container: paperclip-rootless"
echo "  Data volume: $PAPERCLIP_DATA_VOLUME"
echo "  Workspace volume: $PAPERCLIP_WORKSPACE_VOLUME"
echo "  Credentials: $PAPERCLIP_BOOTSTRAP_ADMIN_EMAIL / $PAPERCLIP_BOOTSTRAP_ADMIN_PASSWORD"
echo "  Stop: $REPO_ROOT/scripts/docker-paperclip-stop.sh"
