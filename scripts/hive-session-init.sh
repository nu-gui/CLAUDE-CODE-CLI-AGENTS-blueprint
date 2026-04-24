#!/bin/bash
#
# hive-session-init.sh
# Creates a new session in the Live Hive system
#
# Usage: hive-session-init.sh PROJECT_KEY [OBJECTIVE] [--dev]
#
# Arguments:
#   PROJECT_KEY   - Project identifier in kebab-case format (required)
#   OBJECTIVE     - Session objective description (optional)
#   --dev         - Enable development mode (optional flag)
#
# Exit codes:
#   0 - Success
#   1 - Validation failure (empty/invalid PROJECT_KEY, directory creation failure, etc.)
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
HIVE_ROOT="${HOME}/.claude/context/hive"
ACTIVE_DIR="${HIVE_ROOT}/active"
EVENTS_FILE="${HIVE_ROOT}/events.ndjson"

# Default mode
MODE="production"

# Error handling
error_exit() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}WARNING: $1${NC}" >&2
}

info() {
    echo -e "${GREEN}$1${NC}" >&2
}

# Parse arguments
PROJECT_KEY=""
OBJECTIVE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev)
            MODE="development"
            shift
            ;;
        *)
            if [ -z "$PROJECT_KEY" ]; then
                PROJECT_KEY="$1"
            elif [ -z "$OBJECTIVE" ]; then
                OBJECTIVE="$1"
            else
                error_exit "Too many arguments. Usage: $0 PROJECT_KEY [OBJECTIVE] [--dev]"
            fi
            shift
            ;;
    esac
done

# Validate PROJECT_KEY is provided
if [ -z "$PROJECT_KEY" ]; then
    error_exit "Usage: $0 PROJECT_KEY [OBJECTIVE] [--dev]"
fi

# Validate PROJECT_KEY format (kebab-case, non-empty)
if ! [[ "$PROJECT_KEY" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    error_exit "PROJECT_KEY must be in kebab-case format (lowercase letters, numbers, hyphens only)"
fi

# Generate SESSION_ID: {PROJECT_KEY}_{YYYY-MM-DD}_{HHmm}
TIMESTAMP=$(date -u +%Y-%m-%d_%H%M)
SESSION_ID="${PROJECT_KEY}_${TIMESTAMP}"

# Ensure hive directories exist
mkdir -p "${ACTIVE_DIR}" || error_exit "Failed to create active directory"
mkdir -p "${HIVE_ROOT}/completed" || error_exit "Failed to create completed directory"

# Check if session already exists
if [ -d "${ACTIVE_DIR}/${SESSION_ID}" ]; then
    error_exit "Session ${SESSION_ID} already exists"
fi

# Create session directory structure
SESSION_DIR="${ACTIVE_DIR}/${SESSION_ID}"
mkdir -p "${SESSION_DIR}/agents" || error_exit "Failed to create session directory structure"

info "Creating session: ${SESSION_ID} (mode: ${MODE})"

# Create manifest.yaml
cat > "${SESSION_DIR}/manifest.yaml" <<EOF
session_id: ${SESSION_ID}
project_key: ${PROJECT_KEY}
started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
status: active
mode: ${MODE}
objective: |
  ${OBJECTIVE}
spawned_agents: []
EOF

# Create empty tasks.yaml
cat > "${SESSION_DIR}/tasks.yaml" <<EOF
# Task registry for session ${SESSION_ID}
# Format:
# - task_id: string
#   agent: string
#   status: pending|in_progress|blocked|completed
#   created: ISO8601
#   updated: ISO8601
#   description: string

tasks: []
EOF

# Ensure events.ndjson exists
touch "${EVENTS_FILE}" || error_exit "Failed to create/access events file"

# Append SESSION_START event to events.ndjson — use jq so all string fields
# (especially OBJECTIVE, which is user-supplied) are properly JSON-escaped.
# Raw echo/heredoc interpolation is the root cause of invalid NDJSON (issue #130).
jq -n \
  --arg ts        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sid       "${SESSION_ID}" \
  --arg pk        "${PROJECT_KEY}" \
  --arg mode      "${MODE}" \
  --arg objective "${OBJECTIVE}" \
  '{"v":1,"ts":$ts,"sid":$sid,"project_key":$pk,"agent":"system","event":"SESSION_START","mode":$mode,"objective":$objective}' \
  >> "${EVENTS_FILE}" || error_exit "Failed to write SESSION_START event"

# Create a README in the session directory
cat > "${SESSION_DIR}/README.md" <<EOF
# Session: ${SESSION_ID}

**Project**: ${PROJECT_KEY}
**Started**: $(date -u +%Y-%m-%d %H:%M:%S UTC)
**Status**: Active

## Objective
${OBJECTIVE}

## Directory Structure
- \`agents/\` - Agent-specific state and outputs
- \`manifest.yaml\` - Session metadata
- \`tasks.yaml\` - Task registry

## Session Management
- **Close session**: \`hive-session-close.sh ${SESSION_ID}\`
- **View events**: \`grep '"sid":"${SESSION_ID}"' ${EVENTS_FILE}\`
EOF

info "Session initialized successfully"
info "Session directory: ${SESSION_DIR}"

# Output SESSION_ID to stdout (for programmatic use)
echo "${SESSION_ID}"

exit 0
