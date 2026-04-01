#!/bin/bash
# Grant a running sandbox access to an additional host directory or file.
# Must be run as root (sudo). Paths are mirrored by default.
#
# Usage: sudo ./sandbox-grant.sh [options] <session> <path> [sandbox-path]
#   session:      sandbox session name (from sandbox-start.sh --name)
#   path:         host directory/file to grant access to
#   sandbox-path: path inside the sandbox (default: same as host path)
#
# Options:
#   --ro              Mount read-only
#   --hide <relpath>  Hide a relative path within the mounted directory
#                     (can be specified multiple times)
#
# Examples:
#   sudo ./sandbox-grant.sh myproject /home/user/project
#   sudo ./sandbox-grant.sh myproject --ro /home/user/reference
#   sudo ./sandbox-grant.sh myproject /home/user/project --hide .env --hide .secrets

set -euo pipefail

SESSIONS_FILE="/tmp/sandbox-info.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse options
READONLY=""
HIDE_ARGS=()
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ro)
            READONLY=1
            shift
            ;;
        --hide)
            HIDE_ARGS+=(-H "$2")
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -lt 2 || ${#POSITIONAL[@]} -gt 3 ]]; then
    echo "Usage: sudo $0 [--ro] [--hide path]... <session> <path> [sandbox-path]" >&2
    exit 1
fi

SESSION_NAME="${POSITIONAL[0]}"
HOST_PATH="${POSITIONAL[1]}"
SANDBOX_PATH="${POSITIONAL[2]:-$HOST_PATH}"

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

# Build sandbox-mount arguments
MOUNT_ARGS=()
[[ -n "$READONLY" ]] && MOUNT_ARGS+=(-r)
MOUNT_ARGS+=("${HIDE_ARGS[@]}")

# Inject the mount using open_tree() + move_mount()
"$SCRIPT_DIR/sandbox-mount" "${MOUNT_ARGS[@]}" "$PID" "$HOST_PATH" "$SANDBOX_PATH"

echo "Granted: $HOST_PATH -> $SANDBOX_PATH (session: $SESSION_NAME)"
