#!/bin/bash
# swarmbar-bridge-v3
# SwarmBar hook bridge. Claude Code invokes this with the event name as $1
# and the hook payload on stdin; it forwards both to the SwarmBar menu bar
# app and prints whatever SwarmBar answers (a permission decision for held
# PermissionRequest events, otherwise {}).
#
# It talks only to SwarmBar's own Unix socket, in a folder only this user
# can enter, never to a network port: a port can be taken by any process
# while SwarmBar is not running, and whatever held it would receive every
# payload and could answer allow. No token is sent; reaching the socket at
# all proves the caller is this user.
#
# Fails open by design: if the socket is missing, or is not a socket this
# user owns in a folder this user owns, nothing is sent and nothing is
# printed, and the session shows its own prompt exactly as if unhooked.
EVENT="${1:-Unknown}"
DIR="$HOME/Library/Application Support/SwarmBar/run"
SOCK="$DIR/hook.sock"
if [ ! -L "$DIR" ] && [ -d "$DIR" ] && [ -O "$DIR" ] \
  && [ ! -L "$SOCK" ] && [ -S "$SOCK" ] && [ -O "$SOCK" ]; then
  curl -s --unix-socket "$SOCK" --connect-timeout 1 -m 350 \
    -H "X-Claude-Account: ${CLAUDE_ACCOUNT_LABEL:-}" \
    -X POST --data-binary @- \
    "http://swarmbar/hook/${EVENT}" 2>/dev/null || true
fi
exit 0
