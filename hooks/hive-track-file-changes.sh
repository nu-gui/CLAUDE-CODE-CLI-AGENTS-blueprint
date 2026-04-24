#!/bin/bash
# hive-track-file-changes.sh — Runs on PostToolUse for Edit/Write tools
# Auto-logs file modifications to the active session's checkpoint file
# Advisory (exit 0) — appends checkpoint data silently

INPUT=$(cat /dev/stdin)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Only track Edit and Write operations
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

# Extract file path from tool input
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')
[ -z "$FILE_PATH" ] && exit 0

# Skip files inside ~/.claude/ (meta-files, not project files)
case "$FILE_PATH" in
  */.claude/*) exit 0 ;;
esac

# Resolve PROJECT_KEY
PROJECT_KEY=""
if [ -n "$CWD" ] && [ -d "$CWD/.git" ]; then
  PROJECT_KEY=$(cd "$CWD" && git remote get-url origin 2>/dev/null | sed 's|.*/||;s|\.git$||')
fi
[ -z "$PROJECT_KEY" ] && exit 0

# Find latest session for this project
LATEST_SESSION=$(ls -dt "$HOME/.claude/context/hive/sessions/${PROJECT_KEY}_"* 2>/dev/null | head -1)
[ -z "$LATEST_SESSION" ] && exit 0

# Determine which agent is active (best-effort from session status files)
AGENT="unknown"
ACTIVE_AGENT=$(ls -t "$LATEST_SESSION/agents/"*.status 2>/dev/null | head -1)
if [ -n "$ACTIVE_AGENT" ]; then
  AGENT=$(grep "^agent:" "$ACTIVE_AGENT" 2>/dev/null | awk '{print $2}')
fi

# Write checkpoint
CHECKPOINT_DIR="$LATEST_SESSION/agents/${AGENT}"
mkdir -p "$CHECKPOINT_DIR"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "{\"ts\":\"$TS\",\"action\":\"FILE_MODIFY\",\"path\":\"$FILE_PATH\",\"tool\":\"$TOOL_NAME\"}" >> "$CHECKPOINT_DIR/checkpoints.ndjson"

exit 0
