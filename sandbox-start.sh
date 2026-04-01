#!/bin/bash
# Start an interactive bash shell inside a bubblewrap sandbox.
# Paths inside the sandbox mirror the host filesystem structure.
#
# Usage: ./sandbox-start.sh [--name SESSION] [path]
#   --name SESSION: name for this sandbox session (default: auto-generated UUID)
#   path:           directory to mount read-write (default: $PWD)
#
# The session is registered in /tmp/sandbox-info.json so that
# sandbox-grant.sh and sandbox-revoke.sh can look it up by name.

set -euo pipefail

SESSIONS_FILE="/tmp/sandbox-info.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
SESSION_NAME=""
INITIAL_BIND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) SESSION_NAME="$2"; shift 2 ;;
        *)      INITIAL_BIND="$1"; shift ;;
    esac
done

SESSION_NAME="${SESSION_NAME:-$(uuidgen)}"
INITIAL_BIND="$(realpath "${INITIAL_BIND:-$PWD}")"

if [[ ! -d "$INITIAL_BIND" ]]; then
    echo "Error: $INITIAL_BIND is not a directory" >&2
    exit 1
fi

# The user's home directory is mounted as a host-backed directory so that
# sandbox-grant.sh can create mount point directories on a real filesystem
# (avoiding EOVERFLOW on user-namespace-owned tmpfs).
HOME_PREFIX="$HOME"

RELATIVE="${INITIAL_BIND#"$HOME_PREFIX"/}"
if [[ "$RELATIVE" == "$INITIAL_BIND" ]]; then
    echo "Error: $INITIAL_BIND is not under $HOME_PREFIX" >&2
    exit 1
fi

SANDBOX_HOME=$(mktemp -d /tmp/sandbox-home.XXXXXX)
mkdir -p "$SANDBOX_HOME/$RELATIVE"

# Per-session file where bwrap writes {"child-pid": ...} via --info-fd.
# bwrap writes this before exec'ing bash, so the PID is available
# by the time the user can interact with another terminal.
BWRAP_INFO=$(mktemp /tmp/sandbox-bwrap.XXXXXX)

# Register session in the shared sessions file (with flock)
(
    flock -x 9
    SESSIONS="{}"
    [[ -s "$SESSIONS_FILE" ]] && SESSIONS=$(cat "$SESSIONS_FILE")
    echo "$SESSIONS" | jq \
        --arg name "$SESSION_NAME" \
        --arg info "$BWRAP_INFO" \
        --arg home "$HOME_PREFIX" \
        --arg shome "$SANDBOX_HOME" \
        '.[$name] = {info_file: $info, home_prefix: $home, sandbox_home: $shome}' \
        > "${SESSIONS_FILE}.tmp"
    mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
) 9>"${SESSIONS_FILE}.lock"

CLEANED_UP=""
cleanup() {
    [[ -z "$CLEANED_UP" ]] || return
    CLEANED_UP=1

    # Unregister session
    (
        flock -x 9
        if [[ -s "$SESSIONS_FILE" ]]; then
            jq --arg name "$SESSION_NAME" 'del(.[$name])' "$SESSIONS_FILE" \
                > "${SESSIONS_FILE}.tmp"
            mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
            if [[ "$(jq 'length' "$SESSIONS_FILE" 2>/dev/null)" == "0" ]]; then
                rm -f "$SESSIONS_FILE"
            fi
        fi
    ) 9>"${SESSIONS_FILE}.lock"

    rm -rf "$SANDBOX_HOME" 2>/dev/null || true
    rm -f "$BWRAP_INFO"
}
trap cleanup EXIT

echo "Session: $SESSION_NAME"
echo "Sandbox: $INITIAL_BIND (mirrored path)"
echo "---"
echo "In another terminal:"
echo "  sudo $SCRIPT_DIR/sandbox-grant.sh $SESSION_NAME /path/to/grant"
echo "---"

bwrap \
    --unshare-all \
    --share-net \
    --die-with-parent \
    --cap-drop ALL \
    \
    --ro-bind /usr /usr \
    --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 \
    --symlink usr/bin /bin \
    --symlink usr/sbin /sbin \
    \
    --ro-bind /etc/ld.so.cache /etc/ld.so.cache \
    --ro-bind /etc/passwd /etc/passwd \
    --ro-bind /etc/group /etc/group \
    --ro-bind /etc/resolv.conf /etc/resolv.conf \
    --ro-bind /etc/ssl /etc/ssl \
    --ro-bind /etc/pki /etc/pki \
    --ro-bind /etc/hostname /etc/hostname \
    \
    --proc /proc \
    --dev /dev \
    --tmpfs /tmp \
    --bind "$SANDBOX_HOME" "$HOME_PREFIX" \
    \
    --bind "$INITIAL_BIND" "$INITIAL_BIND" \
    \
    --info-fd 3 \
    --chdir "$INITIAL_BIND" \
    -- /bin/bash 3>"$BWRAP_INFO"
