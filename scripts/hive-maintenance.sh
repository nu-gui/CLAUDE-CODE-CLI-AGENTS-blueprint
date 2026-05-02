#!/usr/bin/env bash
# hive-maintenance.sh
#
# Weekly hygiene: archive old sessions, rotate events.ndjson, prune empty
# session folders. Runs Sunday 02:00 local time via cron.
#
# Safe to run manually. Supports --dry-run.

set -euo pipefail

# Shared helpers (issue #35 / #47).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

SESSIONS="$HIVE/sessions"
ARCHIVE="$HIVE/sessions-archive"
EVENTS_ARCHIVE_DIR="$HIVE/archive"

TODAY="$(date -u +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SID="hive-maintenance-${TODAY}"

# Retention window
SESSION_TTL_DAYS="${HIVE_SESSION_TTL_DAYS:-90}"
# Events rotation trigger
EVENTS_ROTATE_BYTES="${HIVE_EVENTS_ROTATE_BYTES:-1048576}"  # 1 MB

DRY_RUN=0
COMPACT_EMPTY_PAYLOADS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)                DRY_RUN=1 ;;
    --compact-empty-payloads) COMPACT_EMPTY_PAYLOADS=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$ARCHIVE" "$EVENTS_ARCHIVE_DIR" "$LOGS_DIR"

emit_event() {
  [[ "$DRY_RUN" -eq 1 ]] && { echo "[dry-run event] $1: $2"; return; }
  hive_emit_event "hive-maintenance" "$1" "$2"
}

emit_event "SPAWN" "dry_run=$DRY_RUN ttl_days=$SESSION_TTL_DAYS rotate_bytes=$EVENTS_ROTATE_BYTES"

# --- 1. Archive old sessions ---
ARCHIVED_COUNT=0
if [[ -d "$SESSIONS" ]]; then
  # Find sessions whose top-level dir mtime is older than TTL
  CUTOFF_EPOCH="$(date -u -d "-${SESSION_TTL_DAYS} days" +%s)"

  # Group by month for tarball organisation. `find -mtime +N` finds older-than.
  OLD_SESSIONS=()
  while IFS= read -r session_dir; do
    [[ -z "$session_dir" ]] && continue
    OLD_SESSIONS+=("$session_dir")
  done < <(find "$SESSIONS" -mindepth 1 -maxdepth 1 -type d -mtime +"$SESSION_TTL_DAYS" 2>/dev/null)

  if [[ "${#OLD_SESSIONS[@]}" -gt 0 ]]; then
    # Tarball by year-month of the session dir's mtime
    declare -A MONTH_DIRS
    for s in "${OLD_SESSIONS[@]}"; do
      ym=$(date -u -d "@$(stat -c %Y "$s")" +%Y-%m 2>/dev/null || echo unknown)
      MONTH_DIRS[$ym]+=" $s"
    done

    for ym in "${!MONTH_DIRS[@]}"; do
      tarball="$ARCHIVE/sessions-${ym}.tar.gz"
      dirs="${MONTH_DIRS[$ym]}"
      count=$(echo "$dirs" | wc -w)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] would archive $count sessions from $ym into $tarball"
      else
        # Append to existing tarball if present (reuse), else create.
        #
        # Atomic-rename pattern: all work is done on a temp file that lives in
        # the same directory as the target (same filesystem guaranteed), so the
        # final `mv -f` is an atomic rename, not a cross-FS copy.  The trap
        # removes intermediate files if the process is interrupted at any point.
        if [[ -f "$tarball" ]]; then
          tmp_gz="${tarball%.gz}.tmp-$$.tar.gz"
          tmp_tar="${tarball%.gz}.tmp-$$.tar"

          # Register cleanup for both intermediates; fires on EXIT/ERR/INT/TERM.
          _cleanup_tmp() { rm -f "$tmp_gz" "$tmp_tar"; }
          trap '_cleanup_tmp' EXIT ERR INT TERM

          # Copy the original into the temp path — original stays intact.
          cp "$tarball" "$tmp_gz"
          # Decompress the copy (tmp_gz → tmp_tar); original still untouched.
          gunzip "$tmp_gz"
          # Append new session dirs into the temp tar.
          for s in $dirs; do tar -rf "$tmp_tar" -C "$SESSIONS" "$(basename "$s")"; done
          # Recompress; tmp_tar is consumed, tmp_gz is recreated.
          gzip -9 "$tmp_tar"
          # Atomic rename: replaces the original only when everything succeeded.
          mv -f "$tmp_gz" "$tarball"

          # Disarm the cleanup trap — the temp files no longer exist.
          trap - EXIT ERR INT TERM
        else
          # Create fresh
          tar_input=""
          for s in $dirs; do tar_input+=" $(basename "$s")"; done
          tar -czf "$tarball" -C "$SESSIONS" $tar_input
        fi
        # Remove originals after successful tar
        for s in $dirs; do rm -rf "$s"; done
        ARCHIVED_COUNT=$((ARCHIVED_COUNT + count))
      fi
    done

    emit_event "PROGRESS" "sessions archived: $ARCHIVED_COUNT"
  else
    emit_event "PROGRESS" "no sessions older than ${SESSION_TTL_DAYS}d"
  fi
fi

# --- 2. Rotate events.ndjson if > threshold ---
if [[ -f "$EVENTS" ]]; then
  size=$(stat -c %s "$EVENTS" 2>/dev/null || echo 0)
  if [[ "$size" -gt "$EVENTS_ROTATE_BYTES" ]]; then
    rotated="$EVENTS_ARCHIVE_DIR/events-${TODAY}.ndjson"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] would rotate events.ndjson ($size bytes) to $rotated"
    else
      # Append mode: if rotation target already exists (same day), append
      if [[ -f "$rotated" ]]; then
        cat "$EVENTS" >> "$rotated"
      else
        cp "$EVENTS" "$rotated"
      fi
      gzip -9 "$rotated" 2>/dev/null || true
      # Truncate live file; record the rotation itself
      : > "$EVENTS"
      # Use emit_event (which delegates to hive_emit_event / jq) so the
      # rotation record is also properly escaped NDJSON (issue #130 fix).
      emit_event "PROGRESS" "events.ndjson rotated ($size bytes → ${rotated}.gz)"
    fi
  else
    emit_event "PROGRESS" "events.ndjson size $size bytes < threshold $EVENTS_ROTATE_BYTES — skip rotate"
  fi
fi

# --- 3. Prune empty session folders (shouldn't exist but defensive) ---
if [[ -d "$SESSIONS" ]]; then
  empty_count=0
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] would prune empty session $d"
    else
      rmdir "$d" 2>/dev/null && empty_count=$((empty_count+1))
    fi
  done < <(find "$SESSIONS" -mindepth 1 -maxdepth 1 -type d -empty 2>/dev/null)
  [[ "$empty_count" -gt 0 ]] && emit_event "PROGRESS" "pruned $empty_count empty session folders"
fi

# --- 4. Truncate old logs ---
if [[ -d "$LOGS_DIR" ]]; then
  old_logs=$(find "$LOGS_DIR" -name "*.log" -mtime +30 2>/dev/null | wc -l)
  if [[ "$old_logs" -gt 0 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] would gzip $old_logs logs older than 30d"
    else
      find "$LOGS_DIR" -name "*.log" -mtime +30 -exec gzip -9 {} \; 2>/dev/null
      emit_event "PROGRESS" "gzipped $old_logs logs older than 30d"
    fi
  fi
fi

# --- 5. Compact historical empty-payload TOOL_FAILURE events (issue #45) ---
# Before PR #37 (2026-04-19), hooks/hive-tool-failure.sh logged thousands of
# entries with empty `tool` and empty `error` (jq `//` fallthrough bug + the
# PostToolUseFailure payload sometimes carrying {"tool_name":"",...}). These
# are pure noise — ~25% of all events at audit time — and their presence in
# the stream dominates every PR-count / agent-silent heuristic.
#
# Opt-in via --compact-empty-payloads so this doesn't run on every weekly
# cron; a one-off manual run is the intended usage. Idempotent: after PR #37
# is live, subsequent runs catch zero events.
COMPACTED_COUNT=0
if [[ "$COMPACT_EMPTY_PAYLOADS" -eq 1 && -f "$EVENTS" ]]; then
  removable_count="$(python3 - "$EVENTS" <<'PY'
import json, sys
path = sys.argv[1]
n = 0
with open(path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("event") == "TOOL_FAILURE" and not rec.get("tool") and not rec.get("error"):
            n += 1
print(n)
PY
)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would remove $removable_count empty-payload TOOL_FAILURE events from $EVENTS"
    COMPACTED_COUNT="$removable_count"
  else
    backup_file="$EVENTS_ARCHIVE_DIR/events-archive-$(date -u +%Y%m%d-%H%M%S)-compact-backup.ndjson"
    cp "$EVENTS" "$backup_file"
    tmp_file="$(mktemp)"
    python3 - "$EVENTS" "$tmp_file" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
kept = removed = 0
with open(src) as fin, open(dst, "w") as fout:
    for line in fin:
        if not line.strip():
            continue
        try:
            rec = json.loads(line)
        except Exception:
            # Preserve non-JSON lines (debug, never auto-drop)
            fout.write(line if line.endswith("\n") else line + "\n")
            kept += 1
            continue
        if rec.get("event") == "TOOL_FAILURE" and not rec.get("tool") and not rec.get("error"):
            removed += 1
            continue
        fout.write(line if line.endswith("\n") else line + "\n")
        kept += 1
PY
    mv "$tmp_file" "$EVENTS"
    COMPACTED_COUNT="$removable_count"
    emit_event "PROGRESS" "compacted $COMPACTED_COUNT empty TOOL_FAILURE events; backup=$backup_file"
  fi
fi

emit_event "COMPLETE" "maintenance sweep done — archived=$ARCHIVED_COUNT sessions compacted=$COMPACTED_COUNT events"
echo "hive-maintenance: done (archived=$ARCHIVED_COUNT sessions, compacted=$COMPACTED_COUNT events)"
