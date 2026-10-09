#!/bin/sh
# swarmbar-bridge-v2
# SwarmBar bridge for Kimi Code hooks. Registered in
# ~/.kimi-code/config.toml as [[hooks]] entries that pass the event name
# as the first argument. All registered Kimi events are relayed
# fire-and-forget; Kimi's permission prompts cannot be answered through
# hooks (the prompt waits for PreToolUse to finish, so holding would
# freeze the TUI), so SwarmBar answers through the terminal instead.
#
# Fails open: an unreadable token file still sends the request with an
# empty token rather than skipping it.
EVENT="$1"
TOKEN_FILE="$HOME/Library/Application Support/SwarmBar/hook-token"
TOKEN=""
[ -r "$TOKEN_FILE" ] && TOKEN="$(cat "$TOKEN_FILE")"
# SwarmBar's reply is discarded, never printed. Nothing in the Kimi family
# needs it, and Kimi and BearCode show a UserPromptSubmit hook's stdout in
# the transcript and pass it to the model as context, so an echoed "{}"
# appeared under every prompt.
curl -s --connect-timeout 1 -m 5 \
  -H "X-SwarmBar-Token: ${TOKEN}" \
  -X POST --data-binary @- \
  "http://127.0.0.1:48620/hook/${EVENT}" >/dev/null 2>&1 || true
exit 0
