#!/bin/bash
#
# hive-doctor.sh
# Hive Doctor - Auto-repair common Hive integrity issues
#
# Usage: hive-doctor.sh [--dry-run]
#
# Exit codes:
#   0 - All repairs successful
#   1 - Some repairs failed
#   2 - Critical error during repair
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
BACKUP_DIR="${HIVE_ROOT}/backups/$(date +%Y%m%d_%H%M%S)"
REPAIR_LOG="${HIVE_ROOT}/repair.log"

# Flags
DRY_RUN=false

# Counters
REPAIRS_ATTEMPTED=0
REPAIRS_SUCCEEDED=0
REPAIRS_FAILED=0

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Usage: $0 [--dry-run]" >&2
            exit 1
            ;;
    esac
done

# Logging functions
log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$REPAIR_LOG"
    echo -e "$1"
}

log_info() {
    log "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    log "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    log "${RED}[ERROR]${NC} $1"
}

log_repair() {
    log "${CYAN}[REPAIR]${NC} $1"
}

section() {
    echo ""
    echo -e "${CYAN}${BOLD}=== $1 ===${NC}"
    log "=== $1 ==="
}

# Start
echo -e "${BOLD}Hive Doctor - Auto-repair Tool${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
fi
echo "Timestamp: $(date -u +%Y-%m-%d\ %H:%M:%S\ UTC)"
echo "Repair log: $REPAIR_LOG"
echo ""

log "=== Hive Doctor Started ==="
if [ "$DRY_RUN" = true ]; then
    log "Mode: DRY RUN"
fi

# Repair 1: Create missing directories
section "Repair Missing Directories"

for dir in "$HIVE_ROOT" "$ACTIVE_DIR" "$COMPLETED_DIR"; do
    if [ ! -d "$dir" ]; then
        ((REPAIRS_ATTEMPTED++))
        log_repair "Creating missing directory: $dir"

        if [ "$DRY_RUN" = false ]; then
            if mkdir -p "$dir"; then
                log_info "Created directory: $dir"
                ((REPAIRS_SUCCEEDED++))
            else
                log_error "Failed to create directory: $dir"
                ((REPAIRS_FAILED++))
            fi
        else
            log_info "[DRY RUN] Would create directory: $dir"
            ((REPAIRS_SUCCEEDED++))
        fi
    fi
done

# Repair 2: Fix malformed manifest.yaml files
section "Repair Malformed Manifests"

if [ -d "$ACTIVE_DIR" ]; then
    for session_dir in "$ACTIVE_DIR"/*; do
        if [ -d "$session_dir" ]; then
            session_name=$(basename "$session_dir")
            manifest="$session_dir/manifest.yaml"

            if [ -f "$manifest" ]; then
                # Check required fields
                missing_fields=""

                for field in session_id project_key started status; do
                    if ! grep -q "^${field}:" "$manifest"; then
                        missing_fields="${missing_fields}${field} "
                    fi
                done

                if [ -n "$missing_fields" ]; then
                    ((REPAIRS_ATTEMPTED++))
                    log_repair "Fixing manifest for session: $session_name (missing: $missing_fields)"

                    if [ "$DRY_RUN" = false ]; then
                        # Create backup
                        backup_file="$BACKUP_DIR/manifest_${session_name}.yaml.bak"
                        mkdir -p "$BACKUP_DIR"
                        cp "$manifest" "$backup_file"
                        log_info "Backup created: $backup_file"

                        # Add missing fields with defaults
                        for field in $missing_fields; do
                            case "$field" in
                                session_id)
                                    echo "session_id: $session_name" >> "$manifest"
                                    ;;
                                project_key)
                                    # Try to extract from session_name
                                    project=$(echo "$session_name" | sed 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}$//')
                                    echo "project_key: ${project:-unknown}" >> "$manifest"
                                    ;;
                                started)
                                    # Use directory creation time as fallback
                                    dir_time=$(stat -c %y "$session_dir" | cut -d'.' -f1 | sed 's/ /T/')Z
                                    echo "started: $dir_time" >> "$manifest"
                                    ;;
                                status)
                                    echo "status: active" >> "$manifest"
                                    ;;
                            esac
                        done

                        log_info "Manifest repaired for session: $session_name"
                        ((REPAIRS_SUCCEEDED++))
                    else
                        log_info "[DRY RUN] Would repair manifest for session: $session_name"
                        ((REPAIRS_SUCCEEDED++))
                    fi
                fi
            else
                # Create missing manifest
                ((REPAIRS_ATTEMPTED++))
                log_repair "Creating missing manifest for session: $session_name"

                if [ "$DRY_RUN" = false ]; then
                    mkdir -p "$BACKUP_DIR"

                    # Extract project_key from session_name
                    project=$(echo "$session_name" | sed 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}_[0-9]\{4\}$//')
                    dir_time=$(stat -c %y "$session_dir" | cut -d'.' -f1 | sed 's/ /T/')Z

                    cat > "$manifest" <<EOF
session_id: $session_name
project_key: ${project:-unknown}
started: $dir_time
status: active
mode: production
objective: |
  (Auto-generated by hive-doctor)
spawned_agents: []
EOF

                    log_info "Manifest created for session: $session_name"
                    ((REPAIRS_SUCCEEDED++))
                else
                    log_info "[DRY RUN] Would create manifest for session: $session_name"
                    ((REPAIRS_SUCCEEDED++))
                fi
            fi
        fi
    done
fi

# Repair 3: Archive stale active sessions (>24h old, no recent events)
section "Archive Stale Sessions"

STALE_THRESHOLD_HOURS=24
CURRENT_TIMESTAMP=$(date +%s)
STALE_THRESHOLD_SECONDS=$((STALE_THRESHOLD_HOURS * 3600))

if [ -d "$ACTIVE_DIR" ] && [ -f "$EVENTS_FILE" ]; then
    for session_dir in "$ACTIVE_DIR"/*; do
        if [ -d "$session_dir" ] && [ -f "$session_dir/manifest.yaml" ]; then
            session_id=$(grep "^session_id:" "$session_dir/manifest.yaml" | cut -d' ' -f2 || echo "")
            started=$(grep "^started:" "$session_dir/manifest.yaml" | cut -d' ' -f2 || echo "")

            if [ -n "$session_id" ] && [ -n "$started" ]; then
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
                                    ((REPAIRS_ATTEMPTED++))
                                    log_repair "Archiving stale session: $session_id (age: $((age_seconds / 3600))h)"

                                    if [ "$DRY_RUN" = false ]; then
                                        # Update manifest to mark as aborted
                                        {
                                            grep -v "^status:" "$session_dir/manifest.yaml"
                                            echo "status: aborted"
                                            echo "ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                                            echo "aborted_reason: Stale session archived by hive-doctor"
                                        } > "$session_dir/manifest.yaml.tmp"
                                        mv "$session_dir/manifest.yaml.tmp" "$session_dir/manifest.yaml"

                                        # Move to completed
                                        mkdir -p "$COMPLETED_DIR"
                                        dest_dir="$COMPLETED_DIR/$session_id"

                                        if [ -d "$dest_dir" ]; then
                                            dest_dir="${dest_dir}_archived_$(date +%s)"
                                        fi

                                        mv "$session_dir" "$dest_dir"
                                        log_info "Archived stale session to: $dest_dir"
                                        ((REPAIRS_SUCCEEDED++))
                                    else
                                        log_info "[DRY RUN] Would archive stale session: $session_id"
                                        ((REPAIRS_SUCCEEDED++))
                                    fi
                                fi
                            fi
                        else
                            # No events found, archive
                            ((REPAIRS_ATTEMPTED++))
                            log_repair "Archiving session with no events: $session_id"

                            if [ "$DRY_RUN" = false ]; then
                                {
                                    grep -v "^status:" "$session_dir/manifest.yaml"
                                    echo "status: aborted"
                                    echo "ended: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                                    echo "aborted_reason: No events found, archived by hive-doctor"
                                } > "$session_dir/manifest.yaml.tmp"
                                mv "$session_dir/manifest.yaml.tmp" "$session_dir/manifest.yaml"

                                mkdir -p "$COMPLETED_DIR"
                                dest_dir="$COMPLETED_DIR/$session_id"

                                if [ -d "$dest_dir" ]; then
                                    dest_dir="${dest_dir}_archived_$(date +%s)"
                                fi

                                mv "$session_dir" "$dest_dir"
                                log_info "Archived session with no events to: $dest_dir"
                                ((REPAIRS_SUCCEEDED++))
                            else
                                log_info "[DRY RUN] Would archive session with no events: $session_id"
                                ((REPAIRS_SUCCEEDED++))
                            fi
                        fi
                    fi
                fi
            fi
        fi
    done
fi

# Repair 4: Remove orphaned status files
section "Remove Orphaned Status Files"

if [ -d "$ACTIVE_DIR" ]; then
    for session_dir in "$ACTIVE_DIR"/*; do
        if [ -d "$session_dir/agents" ]; then
            for status_file in "$session_dir/agents"/*.status; do
                if [ -f "$status_file" ]; then
                    agent_name=$(basename "$status_file" .status)
                    agent_dir="$session_dir/agents/$agent_name"

                    if [ ! -d "$agent_dir" ]; then
                        ((REPAIRS_ATTEMPTED++))
                        session_name=$(basename "$session_dir")
                        log_repair "Removing orphaned status file: $status_file"

                        if [ "$DRY_RUN" = false ]; then
                            mkdir -p "$BACKUP_DIR"
                            cp "$status_file" "$BACKUP_DIR/$(basename "$status_file").bak"

                            rm "$status_file"
                            log_info "Removed orphaned status file for agent $agent_name in session $session_name"
                            ((REPAIRS_SUCCEEDED++))
                        else
                            log_info "[DRY RUN] Would remove orphaned status file: $status_file"
                            ((REPAIRS_SUCCEEDED++))
                        fi
                    fi
                fi
            done
        fi
    done
fi

# Repair 5: Compact old events (>7 days)
section "Compact Old Events"

if [ -f "$EVENTS_FILE" ]; then
    COMPACT_THRESHOLD_DAYS=7
    COMPACT_THRESHOLD_SECONDS=$((COMPACT_THRESHOLD_DAYS * 86400))
    CUTOFF_TIMESTAMP=$((CURRENT_TIMESTAMP - COMPACT_THRESHOLD_SECONDS))
    CUTOFF_DATE=$(date -d "@$CUTOFF_TIMESTAMP" -u +%Y-%m-%dT%H:%M:%SZ)

    OLD_EVENT_COUNT=$(jq -s --arg cutoff "$CUTOFF_DATE" '[.[] | select(.ts < $cutoff)] | length' "$EVENTS_FILE" 2>/dev/null || echo "0")

    if [ "$OLD_EVENT_COUNT" -gt 0 ]; then
        ((REPAIRS_ATTEMPTED++))
        log_repair "Compacting $OLD_EVENT_COUNT events older than $COMPACT_THRESHOLD_DAYS days"

        if [ "$DRY_RUN" = false ]; then
            # Create backup
            mkdir -p "$BACKUP_DIR"
            cp "$EVENTS_FILE" "$BACKUP_DIR/events.ndjson.bak"
            log_info "Backup created: $BACKUP_DIR/events.ndjson.bak"

            # Create archive of old events
            ARCHIVE_FILE="${HIVE_ROOT}/archived_events_$(date +%Y%m%d_%H%M%S).ndjson"
            jq -s --arg cutoff "$CUTOFF_DATE" '.[] | select(.ts < $cutoff)' "$EVENTS_FILE" > "$ARCHIVE_FILE" 2>/dev/null || true

            # Keep only recent events
            jq -s --arg cutoff "$CUTOFF_DATE" '.[] | select(.ts >= $cutoff)' "$EVENTS_FILE" > "${EVENTS_FILE}.tmp" 2>/dev/null || true
            mv "${EVENTS_FILE}.tmp" "$EVENTS_FILE"

            log_info "Archived $OLD_EVENT_COUNT old events to: $ARCHIVE_FILE"
            ((REPAIRS_SUCCEEDED++))
        else
            log_info "[DRY RUN] Would compact $OLD_EVENT_COUNT old events"
            ((REPAIRS_SUCCEEDED++))
        fi
    else
        log_info "No old events to compact (threshold: $COMPACT_THRESHOLD_DAYS days)"
    fi
fi

# Summary
section "Summary"

echo ""
echo -e "Repairs attempted: $REPAIRS_ATTEMPTED"
echo -e "${GREEN}Repairs succeeded: $REPAIRS_SUCCEEDED${NC}"
echo -e "${RED}Repairs failed: $REPAIRS_FAILED${NC}"
echo ""

log "=== Hive Doctor Completed ==="
log "Repairs attempted: $REPAIRS_ATTEMPTED"
log "Repairs succeeded: $REPAIRS_SUCCEEDED"
log "Repairs failed: $REPAIRS_FAILED"

if [ "$REPAIRS_FAILED" -gt 0 ]; then
    echo -e "${RED}Some repairs failed. Check repair log: $REPAIR_LOG${NC}"
    exit 1
elif [ "$REPAIRS_ATTEMPTED" -eq 0 ]; then
    echo -e "${GREEN}No repairs needed. Hive is healthy.${NC}"
    exit 0
else
    echo -e "${GREEN}All repairs completed successfully.${NC}"
    exit 0
fi
