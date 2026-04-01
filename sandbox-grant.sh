#!/bin/bash
# Grant a running sandbox access to an additional host directory.
# Must be run as root (sudo). Paths are mirrored by default.
#
# Usage: sudo ./sandbox-grant.sh <session> <path> [sandbox-path]
#   session:      sandbox session name (from sandbox-start.sh --name)
#   path:         host directory to grant access to
#   sandbox-path: path inside the sandbox (default: same as host path)
#
# Examples:
#   sudo ./sandbox-grant.sh myproject /home/user/other-project
#   sudo ./sandbox-grant.sh myproject /opt/data /home/user/data

set -euo pipefail

SESSIONS_FILE="/tmp/sandbox-info.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: sudo $0 <session> <path> [sandbox-path]" >&2
    exit 1
fi

SESSION_NAME="$1"
HOST_PATH="$2"
SANDBOX_PATH="${3:-$HOST_PATH}"

if [[ ! -e "$HOST_PATH" ]]; then
    echo "Error: $HOST_PATH does not exist" >&2
    exit 1
fi

# If the host path is a symlink, resolve it so we mount the real target.
# The sandbox path stays as the original (symlink) path.
if [[ -L "$HOST_PATH" ]]; then
    HOST_PATH="$(realpath "$HOST_PATH")"
fi

if [[ ! -x "$SCRIPT_DIR/sandbox-mount" ]]; then
    echo "Error: sandbox-mount helper not found. Build it:" >&2
    echo "  gcc -Wall -O2 -o sandbox-mount sandbox-mount.c" >&2
    exit 1
fi

# Look up session — no flock needed for reads (file is atomically replaced)
if [[ ! -s "$SESSIONS_FILE" ]]; then
    echo "Error: no active sessions ($SESSIONS_FILE not found)" >&2
    exit 1
fi

SESSION_DATA=$(jq -r --arg name "$SESSION_NAME" '.[$name] // empty' "$SESSIONS_FILE")
if [[ -z "$SESSION_DATA" ]]; then
    echo "Error: session '$SESSION_NAME' not found" >&2
    echo "Active sessions:" >&2
    jq -r 'keys[]' "$SESSIONS_FILE" >&2
    exit 1
fi

BWRAP_INFO=$(echo "$SESSION_DATA" | jq -r '.info_file')
HOME_PREFIX=$(echo "$SESSION_DATA" | jq -r '.home_prefix')
SANDBOX_HOME=$(echo "$SESSION_DATA" | jq -r '.sandbox_home')

# Read PID from the per-session bwrap info file
if [[ ! -s "$BWRAP_INFO" ]]; then
    echo "Error: bwrap info file $BWRAP_INFO is missing or empty" >&2
    exit 1
fi
PID=$(jq -r '.["child-pid"]' "$BWRAP_INFO")

if [[ ! -d "/proc/$PID" ]]; then
    echo "Error: sandbox process $PID is not running" >&2
    exit 1
fi

# Create mount point on the host-backed filesystem
RELATIVE="${SANDBOX_PATH#"$HOME_PREFIX"/}"
if [[ "$RELATIVE" == "$SANDBOX_PATH" ]]; then
    echo "Error: $SANDBOX_PATH is not under $HOME_PREFIX" >&2
    echo "  Dynamic mounts must be under the home directory prefix." >&2
    exit 1
fi
# Create mount point: directory for dirs, empty file for files
if [[ -d "$HOST_PATH" ]]; then
    mkdir -p "$SANDBOX_HOME/$RELATIVE"
else
    mkdir -p "$(dirname "$SANDBOX_HOME/$RELATIVE")"
    touch "$SANDBOX_HOME/$RELATIVE"
fi

# Inject the mount using open_tree() + move_mount()
"$SCRIPT_DIR/sandbox-mount" "$PID" "$HOST_PATH" "$SANDBOX_PATH"

echo "Granted: $HOST_PATH -> $SANDBOX_PATH (session: $SESSION_NAME)"
