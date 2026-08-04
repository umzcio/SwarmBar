#!/bin/bash
# swarmbar-bridge-v2
# SwarmBar hook bridge. Claude Code invokes this with the event name as $1
# and the hook payload on stdin; it forwards both to the SwarmBar menu bar
# app and prints whatever SwarmBar answers (a permission decision for held
# PermissionRequest events, otherwise {}).
#
# Fails open by design: if SwarmBar is not running, curl exits nonzero,
# nothing is printed, and the session behaves exactly as if unhooked. The
# same applies if the token file cannot be read: an empty token is sent
# and the server (also fail open) either accepts it because it has no
# token of its own yet, or answers {} as if this were an unknown event.
EVENT="${1:-Unknown}"
TOKEN_FILE="$HOME/Library/Application Support/SwarmBar/hook-token"
TOKEN=""
[ -r "$TOKEN_FILE" ] && TOKEN="$(cat "$TOKEN_FILE")"
curl -s --connect-timeout 1 -m 350 \
  -H "X-Claude-Account: ${CLAUDE_ACCOUNT_LABEL:-}" \
  -H "X-SwarmBar-Token: ${TOKEN}" \
  -X POST --data-binary @- \
  "http://127.0.0.1:48620/hook/${EVENT}" 2>/dev/null || true
