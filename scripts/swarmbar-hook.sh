#!/bin/bash
# SwarmBar hook bridge. Claude Code invokes this with the event name as $1
# and the hook payload on stdin; it forwards both to the SwarmBar menu bar
# app and prints whatever SwarmBar answers (a permission decision for held
# PermissionRequest events, otherwise {}).
#
# Fails open by design: if SwarmBar is not running, curl exits nonzero,
# nothing is printed, and the session behaves exactly as if unhooked.
EVENT="${1:-Unknown}"
curl -s --connect-timeout 1 -m 58 \
  -H "X-Claude-Account: ${CLAUDE_ACCOUNT_LABEL:-}" \
  -X POST --data-binary @- \
  "http://127.0.0.1:48620/hook/${EVENT}" 2>/dev/null || true
