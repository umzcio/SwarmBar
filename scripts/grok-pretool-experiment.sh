#!/bin/bash
# Throwaway experiment, round 3: which deny dialect does Grok's
# pre_tool_use hook runner honor? Marker-keyed so one session tests all
# four. Markers are assembled at runtime so this script's own text never
# matches innocent commands.
CHANNEL="${1:-unknown}"
PAYLOAD=$(cat)
echo "$PAYLOAD" >> "/tmp/swarmbar-grok-hook-log-${CHANNEL}.jsonl"
M="SWARMBAR_DENY"
if echo "$PAYLOAD" | grep -q "${M}_JSON1"; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Denied by SwarmBar J1"}}'
elif echo "$PAYLOAD" | grep -q "${M}_JSON2"; then
  echo '{"hookSpecificOutput":{"hookEventName":"pre_tool_use","permissionDecision":"deny","permissionDecisionReason":"Denied by SwarmBar J2"}}'
elif echo "$PAYLOAD" | grep -q "${M}_JSON3"; then
  echo '{"decision":"block","reason":"Denied by SwarmBar J3"}'
elif echo "$PAYLOAD" | grep -q "${M}_EXIT2"; then
  echo "Denied by SwarmBar E2" >&2
  exit 2
fi
