#!/bin/bash
# hive-subagent-stop.sh — Runs when a subagent finishes (SubagentStop event)
# Verifies the agent emitted required hive events (SPAWN + COMPLETE)
# Advisory only (exit 0) — reports compliance gaps to Claude

INPUT=$(cat /dev/stdin)

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
SESSION_ID_HINT=$(echo "$INPUT" | jq -r '.session_id // empty')

# Skip if no agent type
[ -z "$AGENT_TYPE" ] && exit 0

# Skip non-hive agents (general-purpose, Explore, Plan, etc.)
case "$AGENT_TYPE" in
  Explore|Plan|general-purpose|Bash|claude-code-guide|statusline-setup)
    exit 0
    ;;
esac

EVENTS_FILE=~/.claude/context/hive/events.ndjson

# Check if agent emitted any events in the last 10 minutes
if [ -f "$EVENTS_FILE" ]; then
  RECENT_EVENTS=$(tail -20 "$EVENTS_FILE" | grep "\"agent\":\"$AGENT_TYPE\"" | wc -l)
  if [ "$RECENT_EVENTS" -eq 0 ]; then
    echo "HIVE COMPLIANCE WARNING: Agent '$AGENT_TYPE' completed without emitting events to events.ndjson."
    echo "Required: SPAWN event on start, COMPLETE event on finish."
    echo "Please emit events per _HIVE_PREAMBLE_v3.8.md."
  fi
fi

exit 0
