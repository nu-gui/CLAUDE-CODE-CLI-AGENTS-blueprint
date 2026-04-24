#!/usr/bin/env bash
# evening-sprint-collate.sh
#
# Runs at 21:00 local time via cron. Spawns PLAN-00 to:
#   1. Query all issues labelled product-backlog across ${GITHUB_ORG:-your-org}
#   2. Pull in nightly-candidate carryover from prior sprints
#   3. Prioritise, dedupe against existing open Sprint-YYYY-Www milestone
#   4. Apply nightly-candidate labels + assign to Sprint-<ISOweek> milestone
#   5. Write sprint plan to ~/.claude/context/hive/sprints/<YYYY-MM-DD>.md
#
# The 23:30 nightly selector then sees sprint-blessed issues and boosts those
# repos in its scoring (see nightly-select-projects.sh $sprint_blessed term).

set -euo pipefail

# Shared helpers (issue #35 / #47).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

PROFILES="$CLAUDE_HOME/config/product-profiles.yaml"
SPRINTS_DIR="$HIVE/sprints"
SESSIONS_DIR="$HIVE/sessions"
HANDBOOK="$CLAUDE_HOME/handbook"
HIVE_DEFAULT_AGENT="plan-00"

TODAY="$(date +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ISO_WEEK="$(date +%G-W%V)"             # e.g. 2026-W17 (ISO week)
SPRINT_NAME="Sprint-${ISO_WEEK}"
OWNER="${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org}}"
MAX_SPRINT_ISSUES="${SPRINT_MAX_ISSUES:-16}"  # W18-ID17: doubled default

# Run modes (issue #34):
#   evening (default) — full 21:00 pass, up to 8 issues, nightly-candidate label
#   refresh           — 15:03 mid-day pass, up to 3 issues, adds daytime-candidate
#                       label so overnight dispatch can differentiate priority
MODE="evening"
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=1 ;;
    --mode=evening)  MODE="evening" ;;
    --mode=refresh)  MODE="refresh" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" == "refresh" ]]; then
  MAX_SPRINT_ISSUES="${SPRINT_REFRESH_MAX_ISSUES:-3}"
  SID="sprint-${TODAY}-refresh"
  CANDIDATE_LABEL="daytime-candidate"
else
  SID="sprint-${TODAY}-collate"
  CANDIDATE_LABEL="nightly-candidate"
fi
LOG="$LOGS_DIR/sprint-collation.log"

mkdir -p "$LOGS_DIR" "$SPRINTS_DIR" "$SESSIONS_DIR/$SID/agents"

emit_event() { hive_emit_event "$HIVE_DEFAULT_AGENT" "$1" "$2"; }

# Preflight
command -v gh   >/dev/null || { echo "gh not in PATH" >&2; exit 10; }
command -v jq   >/dev/null || { echo "jq not in PATH" >&2; exit 10; }
command -v claude >/dev/null || { echo "claude not in PATH" >&2; exit 10; }
gh auth status >/dev/null 2>&1 || { echo "gh auth failed" >&2; exit 11; }
[[ -f "$PROFILES" ]] || { echo "profiles missing" >&2; exit 20; }

printf "session_id: %s\nproject_key: all\ncreated: %s\npurpose: sprint-collation\nsprint: %s\n" \
  "$SID" "$NOW_ISO" "$SPRINT_NAME" > "$SESSIONS_DIR/$SID/manifest.yaml"

emit_event "SPAWN" "sprint=$SPRINT_NAME mode=$MODE dry_run=$DRY_RUN max=$MAX_SPRINT_ISSUES"
hive_heartbeat "evening-sprint-collate"

SPRINT_DOC="$SPRINTS_DIR/${TODAY}.md"

PROMPT="$(cat <<PROMPT
SESSION_ID: $SID
PROJECT_KEY: all
DEPTH: depth 0/0
Sprint name: $SPRINT_NAME
Run mode: $MODE         # "evening" (21:00 full pass) | "refresh" (15:03 mid-day top-up)
Candidate label: $CANDIDATE_LABEL   # apply this label to chosen issues
Owner: $OWNER
Max sprint issues: $MAX_SPRINT_ISSUES
Product profiles: $PROFILES
Sprint plan output: $SPRINT_DOC
Dry run: $DRY_RUN
Handbook: $HANDBOOK

Hive protocol: checkpoints + events.ndjson emission per handbook/00-hive-protocol.md.
Tool/skill selection: consult handbook/07-decision-guide.md. Do not ask the user.

You are PLAN-00 running the evening sprint-collation step of the nightly-puffin
pipeline. Your job is to turn today's product-backlog additions (plus any
carryover) into a single coherent sprint that the 23:30 nightly selector will
then execute overnight.

STEPS

1. Query candidate issues across ${GITHUB_ORG:-your-org}:
   - gh search issues --owner=${GITHUB_ORG:-your-org} --state=open --label=product-backlog \\
       --json repository,number,title,labels,updatedAt,body,url --limit 200
   - gh search issues --owner=${GITHUB_ORG:-your-org} --state=open --label=nightly-candidate \\
       --json repository,number,title,labels,milestone,updatedAt,url --limit 200
     (these are carryover — already in a prior sprint but not yet completed)
   - gh search issues --owner=${GITHUB_ORG:-your-org} --state=open --label=doc-hygiene \\
       --json repository,number,title,labels,updatedAt,body,url --limit 200
     (Phase 4 doc-hygiene audit issues — treat like product-backlog for priority.
      These have [DOC] prefix and usually route to doc-00 specialist.)

2. Compute priorities using this order:
   (a) has priority:high  →  P0
   (b) linked to a ROADMAP section (body references ROADMAP.md)  →  P1
   (c) labels include any of: [P0-SEC, security, blocker, critical]  →  P0
   (d) has [tech-debt] prefix  →  P2
   (e) has doc-hygiene label (Phase 4 audit issues)  →  P3 (low-priority but
       eligible for sprint — keeps hygiene work visible without displacing features)
   (f) everything else  →  P2
   Ties broken by repo heat: repos with more open priority:high issues rank first.

3. Dedupe against any open milestone named "$SPRINT_NAME" for each repo. If an
   issue is already in that milestone, keep it (carryover); don't re-add.

4. Choose up to $MAX_SPRINT_ISSUES issues total across all repos. Prefer spreading
   across repos (max 3 from any single repo) unless one repo has > 5 P0 items.

5. For each chosen issue, apply these mutations (only if DRY_RUN=0):
   - Ensure a label "$CANDIDATE_LABEL" exists (label it if not already). In
     evening mode this is "nightly-candidate"; in refresh mode it is
     "daytime-candidate" so dispatch can tell fresh mid-day picks from the
     21:00 baseline sprint.
   - Ensure the issue is attached to milestone "$SPRINT_NAME" on its repo.
     (Create the milestone via \`gh api repos/${GITHUB_ORG:-your-org}/<repo>/milestones -f title="$SPRINT_NAME" -f state="open"\`
      if it doesn't exist yet.)
   - Verify the title has an [AGENT-*] prefix. If missing, infer from labels/body
     and prepend one: [API-CORE] / [DATA-CORE] / [UI-BUILD] / [INFRA-CORE] /
     [FEATURE] (default if no clear signal). Use \`gh issue edit\` to update.

6. Write a sprint-plan markdown document to $SPRINT_DOC with this structure:

   # Sprint plan $SPRINT_NAME (collated $TODAY)

   ## Summary
   - Candidates considered: N
   - Chosen for sprint: M (cap: $MAX_SPRINT_ISSUES)
   - Deferred: K (with reasons)

   ## Chosen (by repo)
   ### <repo>
   - #NN — title — priority:P — agent:<specialist>
   - ...

   ## Deferred (with reason)
   ### <repo>
   - #NN — title — reason: <missing ACs | outside heat | duplicate | budget-cap>

   ## Agent fan-out (expected)
   - api-core: X
   - data-core: Y
   - ui-build: Z
   - infra-core: W
   - (per-specialist breakdown so overnight budget planning is visible)

   ## Notes for overnight
   - (any coupled-group implications, e.g. if telecom-triplet members are all queued)

7. Emit events:
   - PROGRESS per repo with "<repo> chosen=N deferred=M"
   - COMPLETE at end with "sprint=$SPRINT_NAME chosen=N deferred=K"

8. If DRY_RUN=1, skip step 5's mutations — still write the plan doc (prefix it
   with "# [DRY RUN] ...") so the user can inspect before enabling.

CONSTRAINTS
- No code edits. Issue edits only (labels, milestones, title prefix).
- Never close issues here. Never assign assignees.
- If the candidate count is zero, write a plan doc that says "quiet night"
  and emit COMPLETE with chosen=0.
- Respect coupled groups (nightly-repo-profiles.yaml): if an issue touches a
  coupled repo member, flag the sibling repos in the Notes section so the
  nightly stage C2 deploy-group atomicity applies.
PROMPT
)"

emit_event "HANDOFF" "claude -p → PLAN-00 sprint collation"

if claude -p "$PROMPT" \
   --permission-mode acceptEdits \
   --add-dir "$HIVE" \
   --append-system-prompt "You are plan-00-product-delivery in sprint-collation mode running headless. Execute the full collation directly — query issues, apply labels, attach to milestones, write the sprint plan doc. Do not stop at a plan summary; act. Read ~/.claude/handbook/00-hive-protocol.md and ~/.claude/handbook/07-decision-guide.md before acting." \
   > "$LOG" 2>&1; then
  emit_event "COMPLETE" "sprint=$SPRINT_NAME (see $LOG, plan=$SPRINT_DOC)"
  echo "sprint-collation: done → $SPRINT_DOC"
else
  code=$?
  emit_event "BLOCKED" "claude -p exit $code (see $LOG)"
  echo "sprint-collation: FAILED exit $code (see $LOG)" >&2
  exit $code
fi
