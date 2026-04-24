#!/bin/bash
#
# hive-session-close.sh
# Closes an active session in the Live Hive system
#
# Usage: hive-session-close.sh SESSION_ID [STATUS]
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
COMPLETED_DIR="${HIVE_ROOT}/completed"
EVENTS_FILE="${HIVE_ROOT}/events.ndjson"

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

# Validate arguments
if [ $# -lt 1 ]; then
    error_exit "Usage: $0 SESSION_ID [STATUS]"
fi

SESSION_ID="$1"
FINAL_STATUS="${2:-completed}"

# Validate FINAL_STATUS
if ! [[ "$FINAL_STATUS" =~ ^(completed|aborted|failed)$ ]]; then
    warn "Invalid status '${FINAL_STATUS}', using 'completed'"
    FINAL_STATUS="completed"
fi

# Check if session exists in active directory
SESSION_DIR="${ACTIVE_DIR}/${SESSION_ID}"
if [ ! -d "${SESSION_DIR}" ]; then
    error_exit "Session ${SESSION_ID} not found in active sessions"
fi

# Ensure completed directory exists
mkdir -p "${COMPLETED_DIR}"

info "Closing session: ${SESSION_ID}"

# Update manifest.yaml with ended timestamp and final status
MANIFEST_FILE="${SESSION_DIR}/manifest.yaml"
if [ -f "${MANIFEST_FILE}" ]; then
    # Read current manifest
    CURRENT_STATUS=$(grep "^status:" "${MANIFEST_FILE}" | cut -d' ' -f2)

    # Append ended timestamp and update status
    {
        # Remove old status line
        grep -v "^status:" "${MANIFEST_FILE}" || true
        echo "status: ${FINAL_STATUS}"
        echo "ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${MANIFEST_FILE}.tmp"

    mv "${MANIFEST_FILE}.tmp" "${MANIFEST_FILE}"

    info "Updated manifest with status: ${FINAL_STATUS}"
else
    warn "manifest.yaml not found, creating minimal version"
    cat > "${MANIFEST_FILE}" <<EOF
session_id: ${SESSION_ID}
status: ${FINAL_STATUS}
ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
fi

# Count tasks and agents for summary
TASK_COUNT=0
AGENT_COUNT=0

if [ -f "${SESSION_DIR}/tasks.yaml" ]; then
    TASK_COUNT=$(grep -c "^  task_id:" "${SESSION_DIR}/tasks.yaml" 2>/dev/null || echo "0")
fi

if [ -d "${SESSION_DIR}/agents" ]; then
    AGENT_COUNT=$(find "${SESSION_DIR}/agents" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
fi

# Extract project_key from manifest
PROJECT_KEY=$(grep "^project_key:" "${MANIFEST_FILE}" | cut -d' ' -f2 || echo "unknown")

# Append SESSION_END event to events.ndjson — use jq so all string fields are
# properly JSON-escaped. task_count/agent_count are passed as JSON numbers.
# (issue #130: raw heredoc interpolation was a root cause of invalid NDJSON)
jq -n \
  --arg    ts          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg    sid         "${SESSION_ID}" \
  --arg    pk          "${PROJECT_KEY}" \
  --arg    status      "${FINAL_STATUS}" \
  --argjson task_count "${TASK_COUNT}" \
  --argjson agent_count "${AGENT_COUNT}" \
  '{"v":1,"ts":$ts,"sid":$sid,"project_key":$pk,"agent":"system","event":"SESSION_END","status":$status,"task_count":$task_count,"agent_count":$agent_count}' \
  >> "${EVENTS_FILE}" || error_exit "Failed to write SESSION_END event"

# Derive session digest (inline implementation)
info "Deriving session digest..."

# Create digest.yaml with key session artifacts
DIGEST_FILE="${SESSION_DIR}/${SESSION_ID}.digest.yaml"
cat > "${DIGEST_FILE}" <<EOF
# Session Digest: ${SESSION_ID}
# Auto-generated on $(date -u '+%Y-%m-%d %H:%M:%S UTC')

session_id: ${SESSION_ID}
project_key: ${PROJECT_KEY}
status: ${FINAL_STATUS}
task_count: ${TASK_COUNT}
agent_count: ${AGENT_COUNT}
EOF

# Add list of agents that spawned (if any)
if [ -d "${SESSION_DIR}/agents" ] && [ "$(ls -A "${SESSION_DIR}/agents" 2>/dev/null)" ]; then
    echo "agents:" >> "${DIGEST_FILE}"
    for agent_dir in "${SESSION_DIR}/agents"/*; do
        if [ -d "$agent_dir" ]; then
            agent_name=$(basename "$agent_dir")
            echo "  - ${agent_name}" >> "${DIGEST_FILE}"
        fi
    done
fi

# Add summary if available in manifest
if grep -q "^summary:" "${MANIFEST_FILE}" 2>/dev/null; then
    echo "summary: |" >> "${DIGEST_FILE}"
    grep "^summary:" "${MANIFEST_FILE}" | sed 's/^summary: /  /' >> "${DIGEST_FILE}"
fi

info "Digest created: ${DIGEST_FILE}"

# Move session to completed directory
DEST_DIR="${COMPLETED_DIR}/${SESSION_ID}"
if [ -d "${DEST_DIR}" ]; then
    warn "Destination ${DEST_DIR} already exists, creating unique name"
    UNIQUE_SUFFIX=$(date +%s)
    DEST_DIR="${COMPLETED_DIR}/${SESSION_ID}_${UNIQUE_SUFFIX}"
fi

mv "${SESSION_DIR}" "${DEST_DIR}" || error_exit "Failed to move session to completed directory"

info "Session moved to: ${DEST_DIR}"
info "Summary: ${TASK_COUNT} tasks, ${AGENT_COUNT} agents"
info "Session closed successfully with status: ${FINAL_STATUS}"

# Output completed session path to stdout (for programmatic use)
echo "${DEST_DIR}"

exit 0
