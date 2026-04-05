#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

ensure_writable_for_node() {
    target="$1"
    if [ ! -e "$target" ]; then
        mkdir -p "$target"
    fi
    if gosu node test -w "$target" >/dev/null 2>&1; then
        return 0
    fi
    echo "Fixing ownership on $target"
    chown -R node:node "$target"
}

ensure_writable_for_node /paperclip
ensure_writable_for_node /paperclip/.codex
ensure_writable_for_node /workspace

exec gosu node "$@"
