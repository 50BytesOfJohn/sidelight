#!/bin/bash
# Claude Code status line bridge for Sidelight's Claude Code widget.
#
# Claude Code hands its status line command a JSON description of the session after each response, including the
# plan's 5-hour and weekly limits. This saves it where Sidelight reads it, then passes it on to your own status
# line command, if you name one after this script. In ~/.claude/settings.json:
#
#   "statusLine": {"type": "command", "command": "'/Applications/Sidelight.app/Contents/Resources/claude-code-statusline.sh' ~/.claude/statusline.sh"}
input=$(cat)

# Only inputs with limits: a new session has none until its first response, and shouldn't hide the last known.
case $input in
*'"five_hour"'* | *'"seven_day"'*)
    umask 077
    dir="$HOME/Library/Application Support/Sidelight/Claude Code"
    mkdir -p "$dir" &&
        printf '%s' "$input" >"$dir/.status-line.json.$$" &&
        mv -f "$dir/.status-line.json.$$" "$dir/status-line.json"
    ;;
esac

if [ $# -gt 0 ]; then
    printf '%s' "$input" | "$@"
fi
