#!/bin/sh
# SwarmBar bridge for Kimi Code hooks. Registered in
# ~/.kimi-code/config.toml as [[hooks]] entries that pass the event name
# as the first argument. All registered Kimi events are relayed
# fire-and-forget; Kimi's permission prompts cannot be answered through
# hooks (the prompt waits for PreToolUse to finish, so holding would
# freeze the TUI), so SwarmBar answers through the terminal instead.
EVENT="$1"
curl -s --connect-timeout 1 -m 5 -X POST --data-binary @- \
  "http://127.0.0.1:48620/hook/${EVENT}" 2>/dev/null || true
exit 0
