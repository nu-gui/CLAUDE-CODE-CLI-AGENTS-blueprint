#!/usr/bin/env bash
# hive-precompact-snapshot.sh — Runs on PreCompact event
# Snapshots RESUME_PACKET.md before context window compression
# This preserves continuity data that may reference context about to be compacted
# Advisory (exit 0) — creates snapshot silently

INPUT=$(cat /dev/stdin)

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
COMPACT_REASON=$(echo "$INPUT" | jq -r '.reason // "auto"')

# Resolve PROJECT_KEY from CWD git remote
PROJECT_KEY=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  PROJECT_KEY=$(cd "$CWD" && git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')
fi

# Fall back to directory basename
[ -z "$PROJECT_KEY" ] && PROJECT_KEY=$(basename "$CWD" 2>/dev/null)
[ -z "$PROJECT_KEY" ] && exit 0

# Skip if we're in ~/.claude itself (meta-work)
case "$CWD" in
  */.claude|*/.claude/*)
    exit 0
    ;;
esac

# Find latest active session for this project
LATEST_SESSION=$(ls -dt "$HOME/.claude/context/hive/sessions/${PROJECT_KEY}_"* 2>/dev/null | head -1)
[ -z "$LATEST_SESSION" ] && exit 0

RESUME_PACKET="$LATEST_SESSION/RESUME_PACKET.md"
[ ! -f "$RESUME_PACKET" ] && exit 0

# Create snapshots directory within the session
SNAPSHOTS_DIR="$LATEST_SESSION/snapshots"
mkdir -p "$SNAPSHOTS_DIR"

# Snapshot with timestamp suffix
TS_SUFFIX=$(date -u +%Y%m%dT%H%M%SZ)
SNAPSHOT_FILE="$SNAPSHOTS_DIR/RESUME_PACKET.pre-compact-${TS_SUFFIX}.md"

cp "$RESUME_PACKET" "$SNAPSHOT_FILE"

# Emit PreCompact event to hive
EVENTS_FILE="$HOME/.claude/context/hive/events.ndjson"
SESSION_ID=$(basename "$LATEST_SESSION")
PROJECT_KEY_CLEAN=$(echo "$SESSION_ID" | sed 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}$//')
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Use jq -n so all string fields are properly JSON-escaped (issue #130 fix)
jq -n \
  --arg ts       "$TS" \
  --arg sid      "$SESSION_ID" \
  --arg pk       "$PROJECT_KEY_CLEAN" \
  --arg reason   "$COMPACT_REASON" \
  --arg snapshot "$SNAPSHOT_FILE" \
  '{"v":1,"ts":$ts,"sid":$sid,"project_key":$pk,"agent":"hook","event":"PRECOMPACT","reason":$reason,"snapshot":$snapshot}' \
  >> "$EVENTS_FILE"

exit 0
