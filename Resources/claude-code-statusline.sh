#!/bin/bash
# Claude Code status line bridge for Sidelight's Claude Code widget.
#
# Claude Code hands its status line command a JSON description of the session after each response, including the
# plan's 5-hour and weekly limits. This saves it where Sidelight reads it, then passes it on to your own status
# line command, if you name one after this script. In ~/.claude/settings.json:
#
#   "statusLine": {"type": "command", "command": "'/Applications/Sidelight.app/Contents/Resources/claude-code-statusline.sh' ~/.claude/statusline.sh"}
#
# Each Claude account Claude Code keeps in a folder of its own (CLAUDE_CONFIG_DIR) gets a file of its own, named the
# way Claude Code names that account's keychain item: by the first 8 hex digits of the SHA-256 of the folder's NFC
# form.
input=$(cat)

# Only inputs with limits: a new session has none until its first response, and shouldn't hide the last known.
case $input in
*'"five_hour"'* | *'"seven_day"'*)
    umask 077
    dir="$HOME/Library/Application Support/Sidelight/Claude Code"
    file=status-line.json
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        folder=$(printf '%s' "$CLAUDE_CONFIG_DIR" | /usr/bin/perl -MUnicode::Normalize -CS -0777 -pe '$_ = NFC($_)')
        file="status-line-$(printf '%s' "$folder" | /usr/bin/shasum -a 256 | cut -c1-8).json"
    fi
    mkdir -p "$dir" &&
        printf '%s' "$input" >"$dir/.$file.$$" &&
        mv -f "$dir/.$file.$$" "$dir/$file"
    ;;
esac

if [ $# -gt 0 ]; then
    printf '%s' "$input" | "$@"
fi
