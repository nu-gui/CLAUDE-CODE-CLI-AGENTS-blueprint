#!/usr/bin/env bash
# pool-worker.sh
#
# Rate-limit-aware task pool consumer. Issue #31.
#
# Respects the Anthropic 10-tasks-per-hour creation cap by maintaining a
# sliding-window count of `claude -p` spawns we have triggered in the last
# 3600 seconds. Keeps 1 slot per hour in reserve for interactive use, so we
# cap ourselves at 9 spawns / hour.
#
# Producers (nightly-dispatch.sh, product-discovery.sh, issue-planner.sh, ...)
# should enqueue work to dispatch-queue.ndjson instead of calling `claude -p`
# directly when POOL_MODE=1. One queue line looks like:
#
#   {"v":1,"enqueued_at":"2026-04-19T12:00:00Z","agent":"infra-core",
#    "project_key":"example-repo","priority":50,"sid":"b1-2026-04-19",
#    "prompt":"…","add_dirs":["${HOME}/github/${GITHUB_ORG:-your-org}/example-repo"],
#    "append_system_prompt":"…","retry_count":0}
#
# This worker pops at most 1 item per invocation (intended to run every few
# minutes via cron). Items are ordered by priority DESC, then enqueued_at ASC.
# When run under backpressure (queue depth > POOL_BACKPRESSURE_DEPTH) the
# worker emits a QUEUE_BACKPRESSURE event so upstream producers can slow down.
#
# Opt-in: existing scripts only use the pool when POOL_MODE=1 in the
# environment; default behaviour is unchanged.
#
# Usage:
#   pool-worker.sh                 # consume one slot (cron entry)
#   pool-worker.sh --dry-run       # report state, do not spawn
#   pool-worker.sh --status        # print window + queue depth + exit

set -euo pipefail

# Shared helpers (issue #96 / W18-ID5): hive_heartbeat.
# pool-worker sets its own PATH and HIVE before calling hive_cron_path so the
# values stay consistent with the rest of the script.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
HIVE="$CLAUDE_HOME/context/hive"
QUEUE="$HIVE/dispatch-queue.ndjson"
CONSUMED="$HIVE/dispatch-consumed.ndjson"   # audit log of what we spawned
EVENTS="$HIVE/events.ndjson"
LOG_DIR="$HIVE/logs"
mkdir -p "$HIVE" "$LOG_DIR"
touch "$QUEUE" "$CONSUMED" "$EVENTS"

# Tunables (env-overridable)
HOURLY_CAP="${POOL_HOURLY_CAP:-9}"                     # leave 1/hour for interactive
WINDOW_SECONDS="${POOL_WINDOW_SECONDS:-3600}"          # sliding window size
BACKPRESSURE_DEPTH="${POOL_BACKPRESSURE_DEPTH:-50}"    # emit warning above this
LOCK_FILE="$HIVE/.pool-worker.lock"
SID="pool-$(date -u +%Y-%m-%dT%H-%M)"

emit_event() {
  local event="$1" detail="$2"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"v":1,"ts":"%s","sid":"%s","agent":"pool-worker","event":"%s","detail":%s}\n' \
    "$ts" "$SID" "$event" "$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    >> "$EVENTS"
}

# --- Counters -------------------------------------------------------------

window_spawn_count() {
  # Count consumed lines whose spawned_at falls inside the sliding window.
  local cutoff
  cutoff="$(python3 -c "import time; print(int(time.time()) - $WINDOW_SECONDS)")"
  python3 - "$CONSUMED" "$cutoff" <<'PY'
import json, sys, time
from datetime import datetime, timezone
path, cutoff = sys.argv[1], int(sys.argv[2])
n = 0
try:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            ts = rec.get("spawned_at")
            if not ts:
                continue
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if int(dt.timestamp()) >= cutoff:
                    n += 1
            except Exception:
                continue
except FileNotFoundError:
    pass
print(n)
PY
}

queue_depth() {
  # Count non-blank lines. `grep -c` exits 1 when there are zero matches, so
  # without `|| true` the fallback `echo 0` runs on top of grep's own "0" and
  # we end up with a two-line value.
  local n
  n="$(grep -c '.' "$QUEUE" 2>/dev/null || true)"
  echo "${n:-0}"
}

# --- Status mode ----------------------------------------------------------

status_report() {
  local depth count
  depth="$(queue_depth)"
  count="$(window_spawn_count)"
  printf 'pool-worker status:\n'
  printf '  queue depth      : %s\n' "$depth"
  printf '  spawns in window : %s / %s  (window=%ss)\n' "$count" "$HOURLY_CAP" "$WINDOW_SECONDS"
  printf '  backpressure     : %s\n' "$([ "$depth" -gt "$BACKPRESSURE_DEPTH" ] && echo YES || echo no)"
}

if [[ "${1:-}" == "--status" ]]; then
  status_report
  exit 0
fi

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

# --- Exclusive run --------------------------------------------------------

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  emit_event "PROGRESS" "another pool-worker already running; exit"
  exit 0
fi

emit_event "SPAWN" "pool tick (cap=$HOURLY_CAP window=${WINDOW_SECONDS}s)"
hive_heartbeat "pool-worker"

# Backpressure signal (non-blocking; producers decide what to do)
depth="$(queue_depth)"
if [[ "$depth" -gt "$BACKPRESSURE_DEPTH" ]]; then
  emit_event "QUEUE_BACKPRESSURE" "queue_depth=$depth threshold=$BACKPRESSURE_DEPTH"
fi

emit_event "PROGRESS" "queue_depth=$depth"

# Rate-limit gate
current="$(window_spawn_count)"
emit_event "HOURLY_SPAWN_COUNT" "count=$current cap=$HOURLY_CAP"
if [[ "$current" -ge "$HOURLY_CAP" ]]; then
  emit_event "BLOCKED" "rate-limit: $current spawns in last ${WINDOW_SECONDS}s >= cap $HOURLY_CAP"
  exit 0
fi

# --- Pop highest-priority queue item --------------------------------------

if [[ "$depth" -eq 0 ]]; then
  emit_event "PROGRESS" "queue empty; nothing to do"
  exit 0
fi

# Sort by (priority DESC, enqueued_at ASC), take the head.
WORK_ITEM_FILE="$(mktemp)"
REMAINING_QUEUE_FILE="$(mktemp)"
trap 'rm -f "$WORK_ITEM_FILE" "$REMAINING_QUEUE_FILE"' EXIT

python3 - "$QUEUE" "$WORK_ITEM_FILE" "$REMAINING_QUEUE_FILE" <<'PY'
import json, sys
src, head_path, rest_path = sys.argv[1], sys.argv[2], sys.argv[3]
items = []
with open(src) as f:
    for ln in f:
        ln = ln.strip()
        if not ln:
            continue
        try:
            items.append(json.loads(ln))
        except Exception:
            # Preserve malformed lines at the back of the queue so we can debug
            items.append({"_malformed": ln})

# Priority DESC (default 50), then enqueued_at ASC
def keyfn(it):
    if "_malformed" in it:
        return (-1, "")
    return (-int(it.get("priority", 50)), it.get("enqueued_at", ""))

items.sort(key=keyfn)

head = items[0] if items else None
rest = items[1:] if items else []

if head and "_malformed" not in head:
    with open(head_path, "w") as f:
        json.dump(head, f)
else:
    # Nothing to spawn (only malformed lines left)
    open(head_path, "w").close()

with open(rest_path, "w") as f:
    for it in rest:
        if "_malformed" in it:
            f.write(it["_malformed"] + "\n")
        else:
            f.write(json.dumps(it) + "\n")
PY

if [[ ! -s "$WORK_ITEM_FILE" ]]; then
  emit_event "PROGRESS" "queue had only malformed items; nothing spawnable"
  # Rewrite queue with the malformed-kept tail so we don't lose audit trail
  cp "$REMAINING_QUEUE_FILE" "$QUEUE"
  exit 0
fi

# Extract dispatch parameters
AGENT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("agent",""))' "$WORK_ITEM_FILE")"
PROMPT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("prompt",""))' "$WORK_ITEM_FILE")"
PROJECT_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("project_key",""))' "$WORK_ITEM_FILE")"
CHILD_SID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("sid","") or "pool-child-"+__import__("time").strftime("%Y%m%dT%H%M%S"))' "$WORK_ITEM_FILE")"
APPEND_SYS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("append_system_prompt",""))' "$WORK_ITEM_FILE")"

# add_dirs is a JSON list; flatten to --add-dir flags
read -ra ADD_DIR_FLAGS < <(python3 -c '
import json, sys, shlex
dirs = json.load(open(sys.argv[1])).get("add_dirs") or []
# always include HIVE so children can emit events
import os
hive = os.path.expanduser("~/.claude/context/hive")
if hive not in dirs:
    dirs.append(hive)
print(" ".join("--add-dir " + shlex.quote(d) for d in dirs))
' "$WORK_ITEM_FILE")

if [[ "$DRY_RUN" -eq 1 ]]; then
  emit_event "PROGRESS" "DRY-RUN would spawn agent=$AGENT project=$PROJECT_KEY sid=$CHILD_SID"
  # On dry-run we do NOT consume the queue item
  exit 0
fi

emit_event "HANDOFF" "spawn agent=$AGENT project=$PROJECT_KEY sid=$CHILD_SID"

# Commit the pop to the queue before spawning (prevents duplicate spawns if we
# crash mid-run). Audit record lands in dispatch-consumed.ndjson for the
# window counter.
cp "$REMAINING_QUEUE_FILE" "$QUEUE"

SPAWNED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$CONSUMED" "$WORK_ITEM_FILE" "$SPAWNED_AT" "$SID" <<'PY'
import json, sys
consumed_path, item_path, spawned_at, pool_sid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(item_path) as f:
    item = json.load(f)
item["spawned_at"] = spawned_at
item["pool_sid"] = pool_sid
with open(consumed_path, "a") as f:
    f.write(json.dumps(item) + "\n")
PY

# Spawn the specialist per the canonical headless pattern (CLAUDE.md).
LOG_FILE="$LOG_DIR/pool-$CHILD_SID.log"
set +e
claude -p "$PROMPT" \
  --permission-mode acceptEdits \
  "${ADD_DIR_FLAGS[@]}" \
  --add-dir "$HIVE" \
  --append-system-prompt "You are $AGENT running under the pool-worker dispatch. $APPEND_SYS" \
  > "$LOG_FILE" 2>&1
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  emit_event "COMPLETE" "agent=$AGENT project=$PROJECT_KEY sid=$CHILD_SID log=$LOG_FILE"
else
  emit_event "BLOCKED" "agent=$AGENT exit=$rc log=$LOG_FILE"
fi
