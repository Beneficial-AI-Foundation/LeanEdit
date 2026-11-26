#!/bin/sh
# Start this specific build directly and capture startup diagnostics.
# The log contains startup stages, not document text or command arguments.
set -u
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$dir/bin/EditorLean"
log="${XDG_STATE_HOME:-$HOME/.local/state}/editorlean/EditorLean-startup.log"
if [ ! -x "$app" ]; then
    echo "bin/EditorLean must be beside this launcher." >&2
    exit 1
fi
mkdir -p "$(dirname -- "$log")"
{
    echo "EditorLean desktop startup diagnostic"
    date -u
    echo "Executable: $app"
    "$app" --version
    uname -srm
    echo "Session: ${XDG_SESSION_TYPE:-unknown} DISPLAY=${DISPLAY:-} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
} > "$log" 2>&1
echo "Starting EditorLean directly."
echo "Log: $log"
EDITORLEAN_DIAGNOSTICS=1 "$app" "$@" >> "$log" 2>&1
status=$?
echo "Process exit status: $status" >> "$log"
cat "$log"
exit "$status"
