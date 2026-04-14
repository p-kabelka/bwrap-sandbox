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
#   --user USER       Sandbox owner (default: $SUDO_USER; required if not using sudo)
#
# Examples:
#   sudo ./sandbox-grant.sh myproject /home/user/project
#   sudo ./sandbox-grant.sh myproject --ro /home/user/reference
#   sudo ./sandbox-grant.sh myproject /home/user/project --hide .env --hide .secrets

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: must be run as root" >&2
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse options
READONLY=""
SANDBOX_USER=""
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
        --user)
            SANDBOX_USER="$2"
            shift 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [[ ${#POSITIONAL[@]} -lt 2 || ${#POSITIONAL[@]} -gt 3 ]]; then
    echo "Usage: $0 [--ro] [--hide path]... [--user USER] <session> <path> [sandbox-path]" >&2
    exit 1
fi

# Resolve the sandbox owner's runtime directory
SANDBOX_USER="${SANDBOX_USER:-${SUDO_USER:-}}"
if [[ -z "$SANDBOX_USER" ]]; then
    echo "Error: cannot determine sandbox owner; use --user USER" >&2
    exit 1
fi
SESSIONS_FILE="/run/user/$(id -u "$SANDBOX_USER")/sandbox-info.json"

SESSION_NAME="${POSITIONAL[0]}"
HOST_PATH="${POSITIONAL[1]}"
SANDBOX_PATH="${POSITIONAL[2]:-$HOST_PATH}"

if [[ ! -e "$HOST_PATH" ]]; then
    echo "Error: $HOST_PATH does not exist" >&2
    exit 1
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

# Verify PID has not been recycled
EXPECTED_START=$(echo "$SESSION_DATA" | jq -r '.start_time // empty')
if [[ -n "$EXPECTED_START" ]]; then
    CURRENT_START=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null)
    if [[ "$CURRENT_START" != "$EXPECTED_START" ]]; then
        echo "Error: PID $PID has been recycled (start time mismatch)" >&2
        exit 1
    fi
fi

# Verify sandbox is running via flock (survives SIGKILL)
if flock -n 9 9<"$BWRAP_INFO" 2>/dev/null; then
    flock -u 9
    echo "Error: sandbox is not running (lock not held)" >&2
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
chown -R "$SANDBOX_USER:$SANDBOX_USER" "$SANDBOX_HOME"

# Build sandbox-mount arguments
MOUNT_ARGS=()
[[ -n "$READONLY" ]] && MOUNT_ARGS+=(-r)
MOUNT_ARGS+=("${HIDE_ARGS[@]}")

# Inject the mount using open_tree() + move_mount()
"$SCRIPT_DIR/sandbox-mount" "${MOUNT_ARGS[@]}" "$PID" "$HOST_PATH" "$SANDBOX_PATH"

echo "Granted: $HOST_PATH -> $SANDBOX_PATH (session: $SESSION_NAME)"
