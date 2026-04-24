#!/bin/bash
# hive-session-stop.sh — Runs on Stop event (Claude finishes responding)
# Detects active hive sessions and reminds to update landing.yaml + RESUME_PACKET
# Advisory (exit 0) — provides context to Claude for next interaction

INPUT=$(cat /dev/stdin)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Resolve PROJECT_KEY from git remote or directory
PROJECT_KEY=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  PROJECT_KEY=$(cd "$CWD" && git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')
fi

# If no git project, try directory basename
[ -z "$PROJECT_KEY" ] && PROJECT_KEY=$(basename "$CWD" 2>/dev/null)

# Skip if we're in ~/.claude itself (meta-work, not project work)
case "$CWD" in
  */.claude|*/.claude/*)
    exit 0
    ;;
esac

[ -z "$PROJECT_KEY" ] && exit 0

# Check if landing.yaml exists and is stale (>7 days)
LANDING="$HOME/.claude/context/projects/$PROJECT_KEY/landing.yaml"
if [ -f "$LANDING" ]; then
  LANDING_DATE=$(grep "last_updated" "$LANDING" | head -1 | grep -oP '\d{4}-\d{2}-\d{2}')
  if [ -n "$LANDING_DATE" ]; then
    DAYS_AGO=$(( ($(date +%s) - $(date -d "$LANDING_DATE" +%s 2>/dev/null || echo 0)) / 86400 ))
    if [ "$DAYS_AGO" -gt 7 ]; then
      echo "HIVE CONTEXT STALE: landing.yaml for '$PROJECT_KEY' is ${DAYS_AGO} days old."
      echo "Consider updating: ~/.claude/context/projects/$PROJECT_KEY/landing.yaml"
      echo "Fields to update: last_updated, last_session_id, resume_hint"
    fi
  fi
fi

# Check if there's an active session folder that should have RESUME_PACKET updated
LATEST_SESSION=$(ls -dt "$HOME/.claude/context/hive/sessions/${PROJECT_KEY}_"* 2>/dev/null | head -1)
if [ -n "$LATEST_SESSION" ] && [ -f "$LATEST_SESSION/RESUME_PACKET.md" ]; then
  PACKET_AGE=$(( ($(date +%s) - $(stat -c %Y "$LATEST_SESSION/RESUME_PACKET.md" 2>/dev/null || echo 0)) / 3600 ))
  if [ "$PACKET_AGE" -gt 24 ]; then
    echo "HIVE SESSION: RESUME_PACKET.md for $(basename "$LATEST_SESSION") is ${PACKET_AGE}h old."
    echo "Update with current session progress before ending."
  fi
fi

exit 0
