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

SESSIONS_FILE="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR not set}/sandbox-info.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if TIOCSTI is blocked at the kernel level.
# On kernels >= 6.2, dev.tty.legacy_tiocsti defaults to 0.
# When it is not 0, use --new-session to prevent TIOCSTI keypress injection.
# --new-session breaks Ctrl+C forwarding, so it is only used as a fallback.
BWRAP_SESSION_ARGS=()
TIOCSTI_VAL=$(sysctl --values dev.tty.legacy_tiocsti 2>/dev/null || echo "unknown")
if [[ "$TIOCSTI_VAL" != "0" ]]; then
    echo "Warning: dev.tty.legacy_tiocsti is '$TIOCSTI_VAL' (not 0)" >&2
    echo "  Using --new-session (Ctrl+C will terminate the sandbox instead of forwarding)." >&2
    echo "  To avoid this: sudo sysctl -w dev.tty.legacy_tiocsti=0" >&2
    BWRAP_SESSION_ARGS+=(--new-session)
fi

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

    kill "$START_TIME_PID" 2>/dev/null || true
    wait "$START_TIME_PID" 2>/dev/null || true

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

# Background: once bwrap writes the info file, record the child's start time
# in the session registry for PID-reuse detection.
(
    while [[ ! -s "$BWRAP_INFO" ]]; do sleep 0.05; done
    PID=$(jq -r '.["child-pid"]' "$BWRAP_INFO")
    START_TIME=$(awk '{print $22}' "/proc/$PID/stat" 2>/dev/null || echo "")
    if [[ -n "$START_TIME" ]]; then
        (
            flock -x 9
            if [[ -s "$SESSIONS_FILE" ]]; then
                jq --arg name "$SESSION_NAME" --arg st "$START_TIME" \
                    '.[$name].start_time = $st' "$SESSIONS_FILE" \
                    > "${SESSIONS_FILE}.tmp"
                mv "${SESSIONS_FILE}.tmp" "$SESSIONS_FILE"
            fi
        ) 9>"${SESSIONS_FILE}.lock"
    fi
) &
START_TIME_PID=$!

bwrap \
    --unshare-all \
    --share-net \
    --die-with-parent \
    --cap-drop ALL \
    "${BWRAP_SESSION_ARGS[@]}" \
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
    --bind "$BWRAP_INFO" /tmp/.sandbox-lock \
    -- bash -c 'exec 8</tmp/.sandbox-lock; flock -x 8; exec bash' 3>"$BWRAP_INFO"
