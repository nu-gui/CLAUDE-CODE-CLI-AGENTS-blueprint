#!/usr/bin/env bash
# hive-stop-failure.sh — Runs on StopFailure event
# Logs API errors, rate limit hits, unexpected stop conditions
# to the hive event stream for post-incident analysis
# Advisory (exit 0) — records failure details silently

INPUT=$(cat /dev/stdin)

STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // "unknown"')
ERROR_MSG=$(echo "$INPUT" | jq -r '.error // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

EVENTS_FILE="$HOME/.claude/context/hive/events.ndjson"

# Resolve PROJECT_KEY from CWD git remote
PROJECT_KEY=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  PROJECT_KEY=$(cd "$CWD" && git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')
fi
[ -z "$PROJECT_KEY" ] && PROJECT_KEY=$(basename "$CWD" 2>/dev/null)

# Find latest active session (any project if no project key)
SESSION_ID=""
if [ -n "$PROJECT_KEY" ]; then
  SESSION_ID=$(ls -dt "$HOME/.claude/context/hive/sessions/${PROJECT_KEY}_"* 2>/dev/null | head -1 | xargs basename 2>/dev/null)
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(ls -dt "$HOME/.claude/context/hive/sessions/"*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null)
fi
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"

PROJECT_KEY_CLEAN=$(echo "$SESSION_ID" | sed 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_.*//')
[ "$PROJECT_KEY_CLEAN" = "$SESSION_ID" ] && PROJECT_KEY_CLEAN="${PROJECT_KEY:-unknown}"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Emit STOP_FAILURE event — use jq -n so all string fields are properly JSON-escaped
# (STOP_REASON and ERROR_MSG can contain characters that would break a raw
# echo-interpolated JSON string; issue #130 fix)
jq -n \
  --arg ts     "$TS" \
  --arg sid    "$SESSION_ID" \
  --arg pk     "$PROJECT_KEY_CLEAN" \
  --arg reason "$STOP_REASON" \
  --arg err    "$ERROR_MSG" \
  '{"v":1,"ts":$ts,"sid":$sid,"project_key":$pk,"agent":"hook","event":"STOP_FAILURE","stop_reason":$reason,"error":$err}' \
  >> "$EVENTS_FILE"

# Advisory output so Claude can see the failure was logged
echo "HIVE: StopFailure recorded — reason: $STOP_REASON. Check events.ndjson for details."

exit 0
