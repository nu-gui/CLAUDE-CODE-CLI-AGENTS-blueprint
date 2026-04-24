#!/bin/bash
# hive-session-end.sh — Runs on SessionEnd event
# Auto-updates landing.yaml with timestamp and latest session ID
# This is the key hook that prevents landing.yaml staleness

INPUT=$(cat /dev/stdin)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Skip if in ~/.claude itself
case "$CWD" in
  */.claude|*/.claude/*)
    exit 0
    ;;
esac

# Resolve PROJECT_KEY
PROJECT_KEY=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  PROJECT_KEY=$(cd "$CWD" && git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')
fi
[ -z "$PROJECT_KEY" ] && exit 0

# Find landing.yaml
LANDING="$HOME/.claude/context/projects/$PROJECT_KEY/landing.yaml"
[ ! -f "$LANDING" ] && exit 0

# Update last_updated timestamp
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if grep -q "^last_updated:" "$LANDING"; then
  sed -i "s|^last_updated:.*|last_updated: \"$TS\"|" "$LANDING"
elif grep -q "last_updated:" "$LANDING"; then
  sed -i "s|last_updated:.*|last_updated: \"$TS\"|" "$LANDING"
fi

# Update last_session_id with latest session folder
LATEST_SESSION=$(ls -dt "$HOME/.claude/context/hive/sessions/${PROJECT_KEY}_"* 2>/dev/null | head -1)
if [ -n "$LATEST_SESSION" ]; then
  SESSION_ID=$(basename "$LATEST_SESSION")
  if grep -q "^last_session_id:" "$LANDING"; then
    sed -i "s|^last_session_id:.*|last_session_id: $SESSION_ID|" "$LANDING"
  fi
fi

exit 0
