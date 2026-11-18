#!/bin/zsh
# Start this specific build without going through application activation.
# The log contains startup diagnostics, not document text.
set -u
editor_diag_dir="${0:A:h}"
editor_diag_app="$editor_diag_dir/EditorLean.app/Contents/MacOS/EditorLean"
editor_diag_log="$editor_diag_dir/EditorLean-startup.log"
if [[ ! -x "$editor_diag_app" ]]; then
    print -r -- "EditorLean.app must be beside this launcher."
    read -r '?Press Return to close.'
    exit 1
fi
{
    print -r -- "EditorLean desktop startup diagnostic"
    /bin/date -u
    print -r -- "Executable: $editor_diag_app"
    "$editor_diag_app" --version
    /usr/bin/sw_vers
} > "$editor_diag_log" 2>&1
print -r -- "Starting EditorLean directly."
print -r -- "Log: $editor_diag_log"
print -r -- "If the editor opens, you can use it normally."
print -r -- "If it hangs or fails, tell me; the log is saved automatically."
EDITORLEAN_DIAGNOSTICS=1 "$editor_diag_app" >> "$editor_diag_log" 2>&1
editor_diag_exit=$?
print -r -- "Process exit status: $editor_diag_exit" >> "$editor_diag_log"
/bin/cat "$editor_diag_log"
read -r '?Press Return to close this Terminal window.'
exit "$editor_diag_exit"
