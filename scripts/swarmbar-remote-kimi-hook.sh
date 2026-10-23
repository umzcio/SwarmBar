#!/bin/sh
# swarmbar-remote-bridge-v1
# SwarmBar bridge for Kimi Code and BearCode hooks on a remote host.
# Registered in config.toml as [[hooks]] entries that pass the event name
# as the first argument. Every event is relayed fire-and-forget to the
# SwarmBar helper's socket in this user's own home: Kimi's permission
# prompts cannot be answered through hooks, so SwarmBar answers them
# through the terminal instead.
#
# No token: the socket is mode 600 inside a mode 700 directory owned by
# this user, so only this user and root can post to it at all.
EVENT="$1"
# The reply is discarded, never printed. Kimi and BearCode show a
# UserPromptSubmit hook's stdout in the transcript and pass it to the model
# as context, so an echoed "{}" would appear under every prompt.
curl -s --unix-socket "$HOME/.swarmbar/hook.sock" --connect-timeout 1 -m 5 \
  -X POST --data-binary @- \
  "http://swarmbar/hook/${EVENT}" >/dev/null 2>&1 || true
exit 0
