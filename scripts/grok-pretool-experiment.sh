#!/bin/bash
# Throwaway experiment: verifies Grok Build's pre_tool_use hook contract.
# Logs every payload so we can see the real schema, and returns a
# Claude-style deny decision only when the tool input contains the magic
# marker SWARMBAR_DENY_TEST. Everything else passes through untouched.
PAYLOAD=$(cat)
echo "$PAYLOAD" >> /tmp/swarmbar-grok-hook-log.jsonl
if echo "$PAYLOAD" | grep -q "SWARMBAR_DENY_TEST"; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied by SwarmBar experiment"}}'
fi
