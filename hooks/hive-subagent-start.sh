#!/usr/bin/env bash
# hive-subagent-start.sh — Runs on SubagentStart event
# Emits a SPAWN event to events.ndjson when a subagent is spawned
# Advisory (exit 0) — auto-logs agent lifecycle for hive observability

INPUT=$(cat /dev/stdin)

# Extract available context from hook payload
AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // empty')
SESSION_ID_HINT=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Skip if no agent type (not a hive agent spawn)
[ -z "$AGENT_TYPE" ] && exit 0

# Skip generic non-hive agent types
case "$AGENT_TYPE" in
  Explore|Plan|general-purpose|Bash|claude-code-guide|statusline-setup)
    exit 0
    ;;
esac

EVENTS_FILE="$HOME/.claude/context/hive/events.ndjson"

# Resolve SESSION_ID: prefer hint from payload, else find latest active session
SESSION_ID="$SESSION_ID_HINT"
if [ -z "$SESSION_ID" ]; then
  # Resolve PROJECT_KEY from CWD git remote
  PROJECT_KEY=""
  if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
    PROJECT_KEY=$(cd "$CWD" && git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')
  fi
  if [ -n "$PROJECT_KEY" ]; then
    SESSION_ID=$(ls -dt "$HOME/.claude/context/hive/sessions/${PROJECT_KEY}_"* 2>/dev/null | head -1 | xargs basename 2>/dev/null)
  fi
fi

# Fall back to most recent session of any project
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(ls -dt "$HOME/.claude/context/hive/sessions/"*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null)
fi

[ -z "$SESSION_ID" ] && exit 0

# Derive project_key from SESSION_ID (format: {project_key}_{YYYY-MM-DD}_{HHmm})
PROJECT_KEY=$(echo "$SESSION_ID" | sed 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_.*//')

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Emit SPAWN event — use jq -n so all string fields are properly JSON-escaped
# (AGENT_TYPE, SESSION_ID, PROJECT_KEY can contain characters that would break
# a raw echo-interpolated JSON string; issue #130 fix)
jq -n \
  --arg ts     "$TS" \
  --arg sid    "$SESSION_ID" \
  --arg pk     "$PROJECT_KEY" \
  --arg agent  "$AGENT_TYPE" \
  '{"v":1,"ts":$ts,"sid":$sid,"project_key":$pk,"agent":$agent,"event":"SPAWN","trigger":"SubagentStart-hook"}' \
  >> "$EVENTS_FILE"

exit 0
