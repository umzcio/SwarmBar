#!/bin/sh
# Sampling rig: log each Kimi hook event's stdin payload with its name so
# the real bridge can be built against observed shapes, then relay to
# SwarmBar's HookServer. PreToolUse sleeps to reveal whether the TUI's
# permission prompt waits for the hook (decides if a held PreToolUse can
# be the native answer channel).
EVENT="$1"
BODY=$(cat)
printf '%s %s begin %s\n' "$(date -u +%FT%TZ)" "$EVENT" "$BODY" >> /tmp/kimi-hook-samples.log
if [ "$EVENT" = "PreToolUse" ]; then
  sleep 12
  printf '%s %s end-after-sleep\n' "$(date -u +%FT%TZ)" "$EVENT" >> /tmp/kimi-hook-samples.log
fi
printf '%s' "$BODY" | curl -s --connect-timeout 1 -m 10 \
  -X POST --data-binary @- \
  "http://127.0.0.1:48620/hook/${EVENT}" 2>/dev/null || true
exit 0
