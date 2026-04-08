#!/bin/bash
# Revoke a sandbox's access to a previously granted directory.
# Must be run as root (sudo). Cleans up the empty mount point afterward.
#
# Usage: sudo ./sandbox-revoke.sh [--user USER] <session> <path>
#   --user USER: sandbox owner (default: $SUDO_USER; required if not using sudo)
#
# Example:
#   sudo ./sandbox-revoke.sh myproject /home/user/other-project

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: must be run as root" >&2
    exit 1
fi

# Parse options
SANDBOX_USER=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
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

if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
    echo "Usage: $0 [--user USER] <session> <path>" >&2
    exit 1
fi

SESSION_NAME="${POSITIONAL[0]}"
SANDBOX_PATH="${POSITIONAL[1]}"

# Resolve the sandbox owner's runtime directory
SANDBOX_USER="${SANDBOX_USER:-${SUDO_USER:-}}"
if [[ -z "$SANDBOX_USER" ]]; then
    echo "Error: cannot determine sandbox owner; use --user USER" >&2
    exit 1
fi
SESSIONS_FILE="/run/user/$(id -u "$SANDBOX_USER")/sandbox-info.json"

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

# Freeze the sandbox to prevent it from observing intermediate states
# (e.g., reading a hidden path after its tmpfs/devnull mask is unmounted
# but before the base mount is removed).
kill -STOP "$PID"
trap 'kill -CONT "$PID" 2>/dev/null' EXIT

# Unmount child mounts first (hide mounts, grants on top of hides),
# then the base mount. Without this, umount fails with "target is busy".
# Read mountinfo from the host; only nsenter for the actual umount calls.
# mountinfo field 5 is the mount path; list sub-mounts deepest-first.
# Collect mount paths under SANDBOX_PATH (deepest first for unmounting).
mapfile -t MOUNTS < <(
    awk -v base="$SANDBOX_PATH" \
        '$5 == base || index($5, base "/") == 1 { print $5 }' \
        "/proc/$PID/mountinfo" \
        | sort -r
)

for mnt in "${MOUNTS[@]}"; do
    nsenter -t "$PID" --mount -- umount "$mnt"
done

kill -CONT "$PID"

# Clean up empty mount point directories/files on the host-backed filesystem.
# Process deepest-first (MOUNTS is already sorted that way), then walk up
# from SANDBOX_PATH removing empty parent directories.
for mnt in "${MOUNTS[@]}"; do
    RELATIVE="${mnt#"$HOME_PREFIX"/}"
    [[ "$RELATIVE" == "$mnt" ]] && continue
    if [[ -d "$SANDBOX_HOME/$RELATIVE" ]]; then
        rmdir "$SANDBOX_HOME/$RELATIVE" 2>/dev/null || true
    else
        rm -f "$SANDBOX_HOME/$RELATIVE" 2>/dev/null || true
    fi
done

RELATIVE="${SANDBOX_PATH#"$HOME_PREFIX"/}"
if [[ "$RELATIVE" != "$SANDBOX_PATH" ]]; then
    CURRENT="$(dirname "$RELATIVE")"
    while [[ -n "$CURRENT" && "$CURRENT" != "." ]]; do
        rmdir "$SANDBOX_HOME/$CURRENT" 2>/dev/null || break
        CURRENT="$(dirname "$CURRENT")"
    done
fi

echo "Revoked: $SANDBOX_PATH (session: $SESSION_NAME)"
