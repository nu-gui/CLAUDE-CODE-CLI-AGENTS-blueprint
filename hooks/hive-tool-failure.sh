#!/usr/bin/env bash
# hive-tool-failure.sh — Runs on PostToolUseFailure event
# Logs tool execution failures to the hive event stream
# Advisory (exit 0) — records failure context for debugging

INPUT=$(cat /dev/stdin)

TOOL_NAME=$(echo "$INPUT" | jq -r '(.tool_name // .toolName // "unknown")')
EXIT_CODE=$(echo "$INPUT" | jq -r '(.exit_code // .exitCode // -1)')
ERROR_MSG=$(echo "$INPUT" | jq -r '(.error // .message // "")' | head -c 200)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Treat empty-string tool names the same as missing — jq's // operator only
# falls through on null, so a payload like {"tool_name":""} leaves TOOL_NAME=""
# and bypasses the "unknown" skip below. That's the source of the thousands of
# empty-tool TOOL_FAILURE events polluting the hive stream.
[ -z "$TOOL_NAME" ] && TOOL_NAME="unknown"

# Skip noise: only log failures for substantive tools
case "$TOOL_NAME" in
  Glob|Read|unknown)
    exit 0
    ;;
esac

# Skip if the error payload is entirely empty (no exit_code signal and no
# error text). These carry zero debugging value and dominate the stream.
if [ "$EXIT_CODE" = "-1" ] || [ "$EXIT_CODE" = "null" ]; then
  if [ -z "$ERROR_MSG" ]; then
    exit 0
  fi
fi

EVENTS_FILE="$HOME/.claude/context/hive/events.ndjson"

# Rate limit: skip if >10 failures this minute
CURRENT_MINUTE=$(date -u +%Y-%m-%dT%H:%M)
RECENT=$(grep -c "$CURRENT_MINUTE" "$EVENTS_FILE" 2>/dev/null)
[ "${RECENT:-0}" -gt 10 ] && exit 0

# Resolve PROJECT_KEY
PROJECT_KEY=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  PROJECT_KEY=$(cd "$CWD" && git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')
fi
[ -z "$PROJECT_KEY" ] && PROJECT_KEY=$(basename "$CWD" 2>/dev/null)

# Find latest active session (strict: must belong to this PROJECT_KEY + be fresh)
SESSION_ID=""
LATEST_DIR=""
if [ -n "$PROJECT_KEY" ]; then
  # Match both underscore-suffix (legacy) and dash-suffix (nightly-puffin) session names
  LATEST_DIR=$(ls -dt "$HOME/.claude/context/hive/sessions/${PROJECT_KEY}_"* \
                          "$HOME/.claude/context/hive/sessions/"*"-${PROJECT_KEY}" \
                2>/dev/null | head -1)
fi
# Fallback: latest session directory overall (risky — we gate with staleness below)
if [ -z "$LATEST_DIR" ]; then
  LATEST_DIR=$(ls -dt "$HOME/.claude/context/hive/sessions/"*/ 2>/dev/null | head -1)
fi
[ -z "$LATEST_DIR" ] && exit 0

# Staleness gate: never attribute a failure to a session folder older than 2h.
# Prevents the hook from re-emitting yesterday's B1 session failures into
# today's event stream when the active session can't be resolved reliably.
if [ -d "$LATEST_DIR" ]; then
  SESSION_AGE=$(( $(date +%s) - $(stat -c %Y "$LATEST_DIR" 2>/dev/null || echo 0) ))
  if [ "$SESSION_AGE" -gt 7200 ]; then
    exit 0
  fi
fi
SESSION_ID=$(basename "$LATEST_DIR" 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

# Extract PROJECT_KEY from SESSION_ID (handles freeform suffixes)
PROJECT_KEY_CLEAN=$(echo "$SESSION_ID" | sed 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_.*//')

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Ensure exit_code is a valid JSON value
EXIT_CODE_SAFE=${EXIT_CODE:-null}
if ! echo "$EXIT_CODE_SAFE" | grep -qE '^-?[0-9]+$|^null$'; then
  EXIT_CODE_SAFE=null
fi

# Emit TOOL_FAILURE event — use jq -n so all string fields are properly JSON-escaped
# (TOOL_NAME and ERROR_MSG can contain characters that would break a raw
# echo-interpolated JSON string; exit_code is passed as a number; issue #130 fix)
jq -n \
  --arg  ts    "$TS" \
  --arg  sid   "$SESSION_ID" \
  --arg  pk    "$PROJECT_KEY_CLEAN" \
  --arg  tool  "$TOOL_NAME" \
  --arg  err   "$ERROR_MSG" \
  --argjson ec "$EXIT_CODE_SAFE" \
  '{"v":1,"ts":$ts,"sid":$sid,"project_key":$pk,"agent":"hook","event":"TOOL_FAILURE","tool":$tool,"exit_code":$ec,"error":$err}' \
  >> "$EVENTS_FILE"

exit 0
