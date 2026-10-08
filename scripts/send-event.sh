#!/bin/bash
# Usage: scripts/send-event.sh [status] [message] [source]
# If stdin is a Claude Code hook payload (JSON), the project dir name is used as the message.
STATUS=${1:-finished}; MSG=${2:-}; SRC=${3:-claude-code}
if [ -z "$MSG" ] && [ ! -t 0 ]; then
  PAYLOAD=$(cat)
  CWD=$(printf '%s' "$PAYLOAD" | /usr/bin/python3 -c 'import sys,json; print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null)
  MSG="Done in $(basename "${CWD:-?}")"
fi
BODY=$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"source":sys.argv[1],"status":sys.argv[2],"message":sys.argv[3]}))' "$SRC" "$STATUS" "${MSG:-Agent finished}")
curl -s -m 2 -X POST http://127.0.0.1:47821/event -H 'Content-Type: application/json' -d "$BODY" >/dev/null || true
