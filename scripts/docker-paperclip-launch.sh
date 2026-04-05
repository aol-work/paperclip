#!/usr/bin/env bash
set -euo pipefail

umask 077

PAPERCLIP_HOME="${PAPERCLIP_HOME:-/paperclip}"
PAPERCLIP_INSTANCE_ID="${PAPERCLIP_INSTANCE_ID:-default}"
INSTANCE_ROOT="${PAPERCLIP_HOME}/instances/${PAPERCLIP_INSTANCE_ID}"
CONFIG_PATH="${PAPERCLIP_CONFIG:-${INSTANCE_ROOT}/config.json}"
CONFIG_DIR="$(dirname "$CONFIG_PATH")"
ENV_PATH="${CONFIG_DIR}/.env"
SECRETS_KEY_PATH="${PAPERCLIP_SECRETS_MASTER_KEY_FILE:-${INSTANCE_ROOT}/secrets/master.key}"
CODEX_HOME="${CODEX_HOME:-${PAPERCLIP_HOME}/.codex}"
HOST_VALUE="${HOST:-0.0.0.0}"
PORT_VALUE="${PORT:-3100}"
PUBLIC_URL="${PAPERCLIP_PUBLIC_URL:-http://localhost:${PORT_VALUE}}"
DEPLOYMENT_MODE="${PAPERCLIP_DEPLOYMENT_MODE:-authenticated}"
DEPLOYMENT_EXPOSURE="${PAPERCLIP_DEPLOYMENT_EXPOSURE:-private}"
UPDATED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
export CODEX_HOME

rand_hex() {
  local bytes="${1:-32}"
  head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

rand_base64() {
  local bytes="${1:-32}"
  head -c "$bytes" /dev/urandom | base64 | tr -d '\n'
}

ensure_env_key() {
  local key="$1"
  local value="$2"

  mkdir -p "$CONFIG_DIR"
  touch "$ENV_PATH"

  if grep -q "^${key}=" "$ENV_PATH"; then
    return 0
  fi

  printf '%s=%s\n' "$key" "$value" >>"$ENV_PATH"
  chmod 600 "$ENV_PATH" || true
}

mkdir -p \
  "$PAPERCLIP_HOME" \
  "$CONFIG_DIR" \
  "$CODEX_HOME" \
  "$INSTANCE_ROOT/logs" \
  "$INSTANCE_ROOT/db" \
  "$INSTANCE_ROOT/data/storage" \
  "$INSTANCE_ROOT/data/backups" \
  "$INSTANCE_ROOT/secrets" \
  /workspace

chmod 700 "$CODEX_HOME" || true

if [[ ! -f "$CODEX_HOME/config.toml" ]]; then
  : >"$CODEX_HOME/config.toml"
  chmod 600 "$CODEX_HOME/config.toml" || true
fi

if [[ ! -e "$INSTANCE_ROOT/workspaces" ]]; then
  ln -s /workspace "$INSTANCE_ROOT/workspaces"
fi

if [[ ! -f "$SECRETS_KEY_PATH" ]]; then
  printf '%s' "$(rand_base64 32)" >"$SECRETS_KEY_PATH"
  chmod 600 "$SECRETS_KEY_PATH" || true
fi

if [[ -z "${PAPERCLIP_AGENT_JWT_SECRET:-}" ]]; then
  ensure_env_key "PAPERCLIP_AGENT_JWT_SECRET" "$(rand_hex 32)"
fi

bootstrap_codex_auth() {
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -f "$CODEX_HOME/auth.json" ]]; then
    return 0
  fi

  if ! command -v codex >/dev/null 2>&1; then
    return 0
  fi

  echo "[paperclip] Bootstrapping Codex CLI API-key auth in $CODEX_HOME"
  if printf '%s\n' "$OPENAI_API_KEY" | codex login --with-api-key >/tmp/paperclip-codex-login.log 2>&1; then
    chmod 600 "$CODEX_HOME/auth.json" "$CODEX_HOME/config.toml" 2>/dev/null || true
    rm -f /tmp/paperclip-codex-login.log
    return 0
  fi

  echo "[paperclip] Codex login bootstrap failed; continuing without persisted Codex auth." >&2
  sed -n '1,80p' /tmp/paperclip-codex-login.log >&2 || true
  rm -f /tmp/paperclip-codex-login.log
}

bootstrap_codex_auth

if [[ ! -f "$CONFIG_PATH" ]]; then
  cat >"$CONFIG_PATH" <<EOF
{
  "\$meta": {
    "version": 1,
    "updatedAt": "${UPDATED_AT}",
    "source": "onboard"
  },
  "database": {
    "mode": "embedded-postgres",
    "embeddedPostgresDataDir": "${INSTANCE_ROOT}/db",
    "embeddedPostgresPort": 54329,
    "backup": {
      "enabled": true,
      "intervalMinutes": 60,
      "retentionDays": 30,
      "dir": "${INSTANCE_ROOT}/data/backups"
    }
  },
  "logging": {
    "mode": "file",
    "logDir": "${INSTANCE_ROOT}/logs"
  },
  "server": {
    "deploymentMode": "${DEPLOYMENT_MODE}",
    "exposure": "${DEPLOYMENT_EXPOSURE}",
    "host": "${HOST_VALUE}",
    "port": ${PORT_VALUE},
    "allowedHostnames": [],
    "serveUi": true
  },
  "telemetry": {
    "enabled": false
  },
  "auth": {
    "baseUrlMode": "explicit",
    "publicBaseUrl": "${PUBLIC_URL}",
    "disableSignUp": false
  },
  "storage": {
    "provider": "local_disk",
    "localDisk": {
      "baseDir": "${INSTANCE_ROOT}/data/storage"
    },
    "s3": {
      "bucket": "paperclip",
      "region": "us-east-1",
      "prefix": "",
      "forcePathStyle": false
    }
  },
  "secrets": {
    "provider": "local_encrypted",
    "strictMode": false,
    "localEncrypted": {
      "keyFilePath": "${SECRETS_KEY_PATH}"
    }
  }
}
EOF
  chmod 600 "$CONFIG_PATH" || true
fi

cd /app
exec node --import ./server/node_modules/tsx/dist/loader.mjs server/dist/index.js
