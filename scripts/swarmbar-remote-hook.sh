#!/bin/sh
# swarmbar-remote-bridge-v1
# SwarmBar hook bridge for Claude Code on a remote host. Claude Code
# invokes this with the event name as $1 and the hook payload on stdin. It
# posts both to the SwarmBar helper's socket in this user's own home, which
# relays them to every connected Mac, and prints whatever comes back: a
# permission decision for a held PermissionRequest, otherwise {}.
#
# No token: the socket is mode 600 inside a mode 700 directory owned by
# this user, so only this user and root can post to it at all.
#
# Fails open by design: with no helper listening, curl exits nonzero,
# nothing is printed, and the session behaves exactly as if unhooked.
EVENT="${1:-Unknown}"
curl -s --unix-socket "$HOME/.swarmbar/hook.sock" --connect-timeout 1 -m 350 \
  -H "X-Claude-Account: ${CLAUDE_ACCOUNT_LABEL:-}" \
  -X POST --data-binary @- \
  "http://swarmbar/hook/${EVENT}" 2>/dev/null || true
