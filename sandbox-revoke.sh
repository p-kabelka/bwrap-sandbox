#!/bin/bash
# Revoke a sandbox's access to a previously granted directory.
# Must be run as root (sudo). Cleans up the empty mount point afterward.
#
# Usage: sudo ./sandbox-revoke.sh <session> <path>
#
# Example:
#   sudo ./sandbox-revoke.sh myproject /home/user/other-project

set -euo pipefail

SESSIONS_FILE="/tmp/sandbox-info.json"

if [[ $# -ne 2 ]]; then
    echo "Usage: sudo $0 <session> <path>" >&2
    exit 1
fi

SESSION_NAME="$1"
SANDBOX_PATH="$2"

# Look up session
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

PID=$(jq -r '.["child-pid"]' "$BWRAP_INFO")

if [[ ! -d "/proc/$PID" ]]; then
    echo "Error: sandbox process $PID is not running" >&2
    exit 1
fi

# Unmount
nsenter -t "$PID" --mount -- umount "$SANDBOX_PATH"

# Clean up the empty mount point directory on the host-backed filesystem
RELATIVE="${SANDBOX_PATH#"$HOME_PREFIX"/}"
if [[ "$RELATIVE" != "$SANDBOX_PATH" ]]; then
    # Remove empty mount point and any empty parents up to SANDBOX_HOME root
    rmdir "$SANDBOX_HOME/$RELATIVE" 2>/dev/null || true
    PARENT="$(dirname "$SANDBOX_HOME/$RELATIVE")"
    while [[ "$PARENT" != "$SANDBOX_HOME" && "$PARENT" != "/" ]]; do
        rmdir "$PARENT" 2>/dev/null || break
        PARENT="$(dirname "$PARENT")"
    done
fi

echo "Revoked: $SANDBOX_PATH (session: $SESSION_NAME)"
