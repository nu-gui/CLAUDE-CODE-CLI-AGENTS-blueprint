#!/bin/bash
#
# hive-verify.sh
# Hive Verification Tool - Checks hive integrity and reports issues
#
# Usage: hive-verify.sh [--project-key PROJECT_KEY]
#
# Exit codes:
#   0 - All checks passed (HEALTHY)
#   1 - Warnings present (DEGRADED)
#   2 - Errors present (UNHEALTHY)
#   3 - Critical issues (CRITICAL)
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
HIVE_ROOT="${HOME}/.claude/context/hive"
ACTIVE_DIR="${HIVE_ROOT}/active"
COMPLETED_DIR="${HIVE_ROOT}/completed"
EVENTS_FILE="${HIVE_ROOT}/events.ndjson"
CONTEXT_ROOT="${HOME}/.claude/context"

# Check counters
PASSED=0
WARNINGS=0
ERRORS=0
CRITICAL=0

# Optional project filter
PROJECT_KEY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-key)
            PROJECT_KEY="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--project-key PROJECT_KEY]" >&2
            exit 1
            ;;
    esac
done

# Output functions
check_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
    ((PASSED++))
}

check_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARNINGS++))
}

check_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    ((ERRORS++))
}

check_critical() {
    echo -e "${RED}${BOLD}[CRITICAL]${NC} $1"
    ((CRITICAL++))
}

section() {
    echo ""
    echo -e "${CYAN}${BOLD}=== $1 ===${NC}"
}

# Start verification
echo -e "${BOLD}Hive Verification Tool${NC}"
echo "Timestamp: $(date -u +%Y-%m-%d\ %H:%M:%S\ UTC)"
if [ -n "$PROJECT_KEY" ]; then
    echo "Project Filter: $PROJECT_KEY"
fi
echo ""

# Check 1: Required directories exist
section "Directory Structure"

if [ -d "$HIVE_ROOT" ]; then
    check_ok "Hive root directory exists: $HIVE_ROOT"
else
    check_critical "Hive root directory missing: $HIVE_ROOT"
fi

if [ -d "$ACTIVE_DIR" ]; then
    check_ok "Active sessions directory exists"
else
    check_error "Active sessions directory missing: $ACTIVE_DIR"
fi

if [ -d "$COMPLETED_DIR" ]; then
    check_ok "Completed sessions directory exists"
else
    check_warn "Completed sessions directory missing: $COMPLETED_DIR"
fi

# Check 2: events.ndjson validity
section "Events File Integrity"

if [ -f "$EVENTS_FILE" ]; then
    check_ok "Events file exists: $EVENTS_FILE"

    # Check if file is valid NDJSON
    INVALID_LINES=0
    LINE_NUM=0
    while IFS= read -r line || [ -n "$line" ]; do
        ((LINE_NUM++))
        if [ -n "$line" ]; then
            if ! echo "$line" | jq empty 2>/dev/null; then
                ((INVALID_LINES++))
                if [ $INVALID_LINES -le 3 ]; then
                    check_error "Invalid JSON at line $LINE_NUM: $(echo "$line" | head -c 80)..."
                fi
            fi
        fi
    done < "$EVENTS_FILE"

    if [ $INVALID_LINES -eq 0 ]; then
        check_ok "All event lines are valid JSON"
    elif [ $INVALID_LINES -gt 3 ]; then
        check_error "Total invalid JSON lines: $INVALID_LINES (showing first 3)"
    fi

    # Check last N events have required fields
    RECENT_EVENT_COUNT=10
    RECENT_INVALID=0

    if [ -s "$EVENTS_FILE" ]; then
        tail -n "$RECENT_EVENT_COUNT" "$EVENTS_FILE" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                # Check required fields for v1 schema
                if echo "$line" | jq -e '.v' >/dev/null 2>&1; then
                    # v1 schema: requires v, ts, sid, project_key, agent, event
                    for field in v ts sid project_key agent event; do
                        if ! echo "$line" | jq -e ".$field" >/dev/null 2>&1; then
                            check_warn "Recent event missing required field '$field': $(echo "$line" | jq -c . 2>/dev/null || echo "$line")"
                            ((RECENT_INVALID++)) || true
                            break
                        fi
                    done
                else
                    # Legacy schema (no version): requires ts, sid, agent, event
                    for field in ts sid agent event; do
                        if ! echo "$line" | jq -e ".$field" >/dev/null 2>&1; then
                            check_warn "Recent event missing required field '$field' (legacy schema): $(echo "$line" | jq -c . 2>/dev/null || echo "$line")"
                            ((RECENT_INVALID++)) || true
                            break
                        fi
                    done
                fi
            fi
        done

        if [ $RECENT_INVALID -eq 0 ]; then
            check_ok "Recent events ($RECENT_EVENT_COUNT) have required fields"
        fi
    fi
else
    check_warn "Events file does not exist (will be created on first session)"
fi

# Check 3: Active sessions have valid manifest.yaml
section "Active Session Integrity"

if [ -d "$ACTIVE_DIR" ]; then
    ACTIVE_COUNT=0
    ACTIVE_INVALID=0

    for session_dir in "$ACTIVE_DIR"/*; do
        if [ -d "$session_dir" ]; then
            ((ACTIVE_COUNT++))
            session_name=$(basename "$session_dir")

            # Filter by project if specified
            if [ -n "$PROJECT_KEY" ]; then
                session_project=$(grep "^project_key:" "$session_dir/manifest.yaml" 2>/dev/null | cut -d' ' -f2 || echo "")
                if [ "$session_project" != "$PROJECT_KEY" ]; then
                    continue
                fi
            fi

            manifest="$session_dir/manifest.yaml"
            if [ -f "$manifest" ]; then
                # Check required fields
                required_fields="session_id project_key started status"
                missing_fields=""

                for field in $required_fields; do
                    if ! grep -q "^${field}:" "$manifest"; then
                        missing_fields="${missing_fields}${field} "
                    fi
                done

                if [ -z "$missing_fields" ]; then
                    check_ok "Valid manifest for session: $session_name"
                else
                    check_error "Session $session_name manifest missing fields: $missing_fields"
                    ((ACTIVE_INVALID++))
                fi
            else
                check_error "Session $session_name missing manifest.yaml"
                ((ACTIVE_INVALID++))
            fi
        fi
    done

    if [ $ACTIVE_COUNT -eq 0 ]; then
        check_ok "No active sessions (clean state)"
    elif [ $ACTIVE_INVALID -eq 0 ]; then
        check_ok "All $ACTIVE_COUNT active session(s) have valid manifests"
    fi
fi

# Check 4: No orphaned status files
section "Orphaned Files Check"

ORPHANED_COUNT=0
if [ -d "$ACTIVE_DIR" ]; then
    for session_dir in "$ACTIVE_DIR"/*; do
        if [ -d "$session_dir/agents" ]; then
            for status_file in "$session_dir/agents"/*.status; do
                if [ -f "$status_file" ]; then
                    agent_name=$(basename "$status_file" .status)
                    agent_dir="$session_dir/agents/$agent_name"

                    if [ ! -d "$agent_dir" ]; then
                        check_warn "Orphaned status file: $status_file (no corresponding agent directory)"
                        ((ORPHANED_COUNT++))
                    fi
                fi
            done
        fi
    done
fi

if [ $ORPHANED_COUNT -eq 0 ]; then
    check_ok "No orphaned status files detected"
fi

# Check 5: landing.yaml exists for active project (if PROJECT_KEY provided)
section "Project Context"

if [ -n "$PROJECT_KEY" ]; then
    LANDING_FILE="$CONTEXT_ROOT/projects/$PROJECT_KEY/landing.yaml"

    if [ -f "$LANDING_FILE" ]; then
        check_ok "landing.yaml exists for project: $PROJECT_KEY"
    else
        check_warn "landing.yaml missing for project: $PROJECT_KEY (CTX-00 may need to cold-start)"
    fi
else
    check_ok "No project filter specified, skipping landing.yaml check"
fi

# Check 6: No duplicate SESSION_IDs in active/
section "Duplicate Detection"

DUPLICATE_COUNT=0
if [ -d "$ACTIVE_DIR" ]; then
    declare -A session_ids

    for session_dir in "$ACTIVE_DIR"/*; do
        if [ -d "$session_dir" ]; then
            session_name=$(basename "$session_dir")

            if [ -f "$session_dir/manifest.yaml" ]; then
                session_id=$(grep "^session_id:" "$session_dir/manifest.yaml" | cut -d' ' -f2)

                if [ -n "$session_id" ]; then
                    if [ -n "${session_ids[$session_id]:-}" ]; then
                        check_error "Duplicate SESSION_ID: $session_id (found in $session_name and ${session_ids[$session_id]})"
                        ((DUPLICATE_COUNT++))
                    else
                        session_ids[$session_id]="$session_name"
                    fi
                fi
            fi
        fi
    done
fi

if [ $DUPLICATE_COUNT -eq 0 ]; then
    check_ok "No duplicate SESSION_IDs detected"
fi

# Check 7: Stale active sessions (>24 hours with no recent events)
section "Stale Session Detection"

STALE_COUNT=0
STALE_THRESHOLD_HOURS=24

if [ -d "$ACTIVE_DIR" ] && [ -f "$EVENTS_FILE" ]; then
    CURRENT_TIMESTAMP=$(date +%s)
    STALE_THRESHOLD_SECONDS=$((STALE_THRESHOLD_HOURS * 3600))

    for session_dir in "$ACTIVE_DIR"/*; do
        if [ -d "$session_dir" ] && [ -f "$session_dir/manifest.yaml" ]; then
            session_id=$(grep "^session_id:" "$session_dir/manifest.yaml" | cut -d' ' -f2)
            started=$(grep "^started:" "$session_dir/manifest.yaml" | cut -d' ' -f2)

            if [ -n "$session_id" ] && [ -n "$started" ]; then
                # Convert ISO8601 to epoch
                started_epoch=$(date -d "$started" +%s 2>/dev/null || echo "0")

                if [ "$started_epoch" -gt 0 ]; then
                    age_seconds=$((CURRENT_TIMESTAMP - started_epoch))

                    if [ $age_seconds -gt $STALE_THRESHOLD_SECONDS ]; then
                        # Check for recent events
                        last_event=$(grep "\"sid\":\"$session_id\"" "$EVENTS_FILE" 2>/dev/null | tail -n 1)

                        if [ -n "$last_event" ]; then
                            last_event_ts=$(echo "$last_event" | jq -r '.ts' 2>/dev/null || echo "")

                            if [ -n "$last_event_ts" ]; then
                                last_event_epoch=$(date -d "$last_event_ts" +%s 2>/dev/null || echo "0")
                                event_age_seconds=$((CURRENT_TIMESTAMP - last_event_epoch))

                                if [ $event_age_seconds -gt $STALE_THRESHOLD_SECONDS ]; then
                                    check_warn "Stale session: $session_id (age: $((age_seconds / 3600))h, last event: $((event_age_seconds / 3600))h ago)"
                                    ((STALE_COUNT++))
                                fi
                            fi
                        else
                            check_warn "Stale session: $session_id (age: $((age_seconds / 3600))h, no events found)"
                            ((STALE_COUNT++))
                        fi
                    fi
                fi
            fi
        fi
    done
fi

if [ $STALE_COUNT -eq 0 ]; then
    check_ok "No stale sessions detected (>24h threshold)"
fi

# Summary
section "Summary"

TOTAL_CHECKS=$((PASSED + WARNINGS + ERRORS + CRITICAL))

echo ""
echo -e "Checks: ${GREEN}$PASSED passed${NC}, ${YELLOW}$WARNINGS warnings${NC}, ${RED}$ERRORS errors${NC}, ${RED}${BOLD}$CRITICAL critical${NC}"
echo ""

# Determine overall status
if [ $CRITICAL -gt 0 ]; then
    echo -e "Hive Status: ${RED}${BOLD}CRITICAL${NC}"
    exit 3
elif [ $ERRORS -gt 0 ]; then
    echo -e "Hive Status: ${RED}UNHEALTHY${NC}"
    exit 2
elif [ $WARNINGS -gt 0 ]; then
    echo -e "Hive Status: ${YELLOW}DEGRADED${NC}"
    exit 1
else
    echo -e "Hive Status: ${GREEN}HEALTHY${NC}"
    exit 0
fi
