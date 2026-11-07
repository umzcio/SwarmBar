#!/bin/sh
# swarmbar-bridge-v3
# SwarmBar bridge for Kimi Code hooks. Registered in
# ~/.kimi-code/config.toml as [[hooks]] entries that pass the event name
# as the first argument. All registered Kimi events are relayed
# fire-and-forget; Kimi's permission prompts cannot be answered through
# hooks (the prompt waits for PreToolUse to finish, so holding would
# freeze the TUI), so SwarmBar answers through the terminal instead.
#
# It talks only to SwarmBar's own Unix socket, in a folder only this user
# can enter, never to a network port another process could be holding. No
# token is sent; reaching the socket at all proves the caller is this user.
# Fails open: anything other than this user's socket sends nothing.
EVENT="$1"
DIR="$HOME/Library/Application Support/SwarmBar/run"
SOCK="$DIR/hook.sock"
# SwarmBar's reply is discarded, never printed. Nothing in the Kimi family
# needs it, and Kimi and BearCode show a UserPromptSubmit hook's stdout in
# the transcript and pass it to the model as context, so an echoed "{}"
# appeared under every prompt.
if [ ! -L "$DIR" ] && [ -d "$DIR" ] && [ -O "$DIR" ] \
  && [ ! -L "$SOCK" ] && [ -S "$SOCK" ] && [ -O "$SOCK" ]; then
  curl -s --unix-socket "$SOCK" --connect-timeout 1 -m 5 \
    -X POST --data-binary @- \
    "http://swarmbar/hook/${EVENT}" >/dev/null 2>&1 || true
fi
exit 0
