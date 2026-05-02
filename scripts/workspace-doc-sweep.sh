#!/usr/bin/env bash
# scripts/workspace-doc-sweep.sh
#
# Workspace-internal documentation sweep — counterpart to doc-hygiene-scan.sh.
#
# `doc-hygiene-scan.sh` operates on the **${GITHUB_ORG:-your-org} org repos** (32 repos
# bucketed across 7 days). This script operates on **~/.claude itself**
# — the live Claude Code workspace — which the org-wide sweeper never
# sees. Without this, workspace docs (CLAUDE.md, handbook/, docs/,
# agents/, plans/, protocols/, context/shared/) drift independently of
# the rest of the universe.
#
# Cadence: weekly Sunday 04:00 local time (1h after smoke-test-weekly's 03:00
# fire so the two heavy jobs don't overlap). Workspace doc churn is
# lower than per-repo churn so daily would be wasteful.
#
# Per-fire scope: ALL workspace doc directories — but the index-README
# regenerators in here are mechanical + idempotent, and the DOC-00
# hygiene dispatch caps deletions at 0 (audit-only mode). Net effect:
# detect-and-flag, never auto-delete in the workspace.
#
# Usage:
#   bash scripts/workspace-doc-sweep.sh                # apply mode (default)
#   bash scripts/workspace-doc-sweep.sh --dry-run      # no mutations
#   bash scripts/workspace-doc-sweep.sh --skip-readmes # only do DOC-00 audit
#
# Outputs:
#   - Refreshed README.md in context/shared/{patterns,decisions,lessons}/
#     (mechanical regen — extracts titles from current file inventory)
#   - DOC-00 audit findings as a manifest at $HIVE/workspace-doc-audit-<date>.md
#
# NOT YET WIRED (future work — track in a follow-up issue):
#   - Auto-PR for any README diffs against ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint
#   - Auto-issue creation with label `workspace-doc-audit` for findings
# For now, the manifest at $HIVE/workspace-doc-audit-<date>.md is the only
# deliverable; the operator reviews it and decides whether to open a PR/issue.
#
# Exit codes:
#   0  success — both phases (README refresh + DOC-00 audit) clean
#   1  fatal — gh auth failure or malformed config (not currently emitted;
#                reserved for future preflight checks)
#   2  partial — DOC-00 dispatch failed but README refresh succeeded
#                (or vice versa). Visible in cron / monitoring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
hive_cron_path

LOCK_FILE="${WORKSPACE_DOC_LOCK:-/tmp/workspace-doc-sweep.lock}"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  hive_emit_event "workspace-doc-sweep" "BLOCKED" \
    "another instance is running (lock=$LOCK_FILE) — exit 0"
  exit 0
fi

DRY_RUN=0
SKIP_READMES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --skip-readmes) SKIP_READMES=1; shift ;;
    *) echo "[workspace-doc-sweep] Unknown flag: $1" >&2; exit 1 ;;
  esac
done

SID="workspace-doc-sweep-$(date -u +%Y%m%dT%H%M%SZ)"
emit() { SID="$SID" hive_emit_event "workspace-doc-sweep" "$1" "$2"; }
emit "SPAWN" "mode=$([ $DRY_RUN -eq 1 ] && echo dry-run || echo apply) skip_readmes=$SKIP_READMES"

# Tracks partial failures across both phases. Bumped to 2 if any subtask
# (README refresh OR DOC-00 dispatch) fails; the final `exit $EXIT_STATUS`
# preserves the failure code so cron + pipeline-health-check see it.
EXIT_STATUS=0

CLAUDE_REPO="${CLAUDE_REPO:-$HOME/.claude}"
cd "$CLAUDE_REPO"

# ---- Refresh the 3 mechanical index READMEs
# These regenerate from the current file inventory; the DOC-00 sub-agent
# isn't needed for them and trying to use the agent led to sandbox-read
# failures during 2026-05-02 Phase C work.
refresh_index_readme() {
  local label="$1"
  local dir="$2"
  local id_prefix="$3"
  local title="$4"
  local intro="$5"
  local add_line="$6"

  local out_path="${dir}/README.md"
  local tmp_path
  tmp_path="$(mktemp /tmp/wssweep-readme.XXXXXX)"

  ID_PREFIX="$id_prefix" DIR="$dir" TITLE="$title" \
  INTRO="$intro" ADD_LINE="$add_line" python3 -c '
import os, re
DIR = os.environ["DIR"]
ID_PREFIX = os.environ["ID_PREFIX"]
files = sorted([f for f in os.listdir(DIR) \
                if re.match(rf"^{ID_PREFIX}-\d+", f) and f.endswith(".md") \
                and f != "README.md"])
print(f"# {os.environ[\"TITLE\"]}")
print()
print(os.environ["INTRO"])
print()
print(os.environ["ADD_LINE"])
print()
print(f"_Total: {len(files)} entries._")
print()
print("| ID | Title | Source file |")
print("|---|---|---|")
for f in files:
    title = "_untitled_"
    try:
        with open(os.path.join(DIR, f)) as fh:
            for line in fh:
                m = re.match(r"^#\s+(.+?)\s*$", line)
                if m:
                    title = m.group(1)[:80]
                    break
    except Exception:
        pass
    pid = re.match(rf"^({ID_PREFIX}-\d+)", f).group(1)
    print(f"| {pid} | {title} | [{f}]({f}) |")
' > "$tmp_path"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if ! diff -q "$out_path" "$tmp_path" >/dev/null 2>&1; then
      echo "[dry-run] $label README would change ($(wc -l < "$tmp_path") lines)"
      emit "PROGRESS" "$label-readme-would-change"
    else
      echo "[dry-run] $label README unchanged"
      emit "PROGRESS" "$label-readme-no-change"
    fi
  else
    if ! diff -q "$out_path" "$tmp_path" >/dev/null 2>&1; then
      cp "$tmp_path" "$out_path"
      echo "[apply] $label README refreshed ($(wc -l < "$out_path") lines)"
      emit "PROGRESS" "$label-readme-refreshed"
    else
      echo "[apply] $label README unchanged"
      emit "PROGRESS" "$label-readme-no-change"
    fi
  fi

  rm -f "$tmp_path"
}

if [[ "$SKIP_READMES" -eq 0 ]]; then
  refresh_index_readme \
    "patterns" \
    "context/shared/patterns" \
    "PATTERN" \
    "Shared design patterns" \
    "Cross-project conventions and reusable approaches captured from completed work." \
    "To add: write \`PATTERN-XXX_<slug>.md\` (next free number) with \`# <Title>\` on line 1, then append a row to the table below."

  refresh_index_readme \
    "decisions" \
    "context/shared/decisions" \
    "DEC" \
    "Architectural decisions (DECs)" \
    "Cross-project decisions with rationale, alternatives considered, and consequences. Created at decision time and immutable thereafter." \
    "To add: write \`DEC-XXX_<slug>.md\` (next free number) with \`# <Title>\` on line 1 and an explicit date marker, then append a row to the table below."

  refresh_index_readme \
    "lessons" \
    "context/shared/lessons" \
    "LESSON" \
    "Operational lessons (LESSONs)" \
    "Post-incident learnings: what failed, why, what we changed to prevent recurrence." \
    "To add: write \`LESSON-XXX_<slug>.md\` (next free number) with sections \`## Symptom / ## Root cause / ## Resolution / ## Prevention\`, then append a row to the table below."
fi

# ---- Workspace audit (DOC-00 in audit-only mode)
# DOC-00 hygiene mode normally classifies (purge/audit/leave) and may
# delete pollution-pattern files. For workspace ops we set
# WORKSPACE_AUDIT_ONLY=1 so the agent ONLY produces an audit manifest —
# no file deletion. Workspace deletes go through review.
emit "PROGRESS" "starting workspace audit (DOC-00 audit-only)"

WORKSPACE_AUDIT_LOG="$HIVE/workspace-doc-audit-$(date -u +%F).md"
if [[ "$DRY_RUN" -eq 0 ]]; then
  # Headless DOC-00 dispatch with workspace-scoped paths. All path refs
  # use $CLAUDE_REPO so the script works correctly when CLAUDE_REPO is
  # overridden (e.g. for testing against a clone at /tmp/test-claude/).
  prompt="$(cat <<PROMPT
SESSION_ID: $SID
MODE: hygiene
AUDIT_ONLY: 1
TARGET: workspace ($CLAUDE_REPO/)
SCOPE: CLAUDE.md, handbook/, docs/, agents/, plans/, protocols/, context/shared/
HANDBOOK: $CLAUDE_REPO/handbook/

You are doc-00-documentation running in workspace audit-only mode.

Read \`$CLAUDE_REPO/agents/doc-00-documentation.md\` lines 272-376 for
hygiene mode details, but DO NOT delete any files in this run. Workspace
files require human review for deletion.

Your job:
  1. Walk the SCOPE directories above (relative to $CLAUDE_REPO)
  2. Apply the rot-indicator + tech-drift checks from
     \`$CLAUDE_REPO/config/doc-hygiene-profiles.yaml\`
  3. Write a single audit manifest at:
     $WORKSPACE_AUDIT_LOG
  4. Each finding: file_path | severity | rule | one-line summary

Do not edit any files. Do not delete any files. Do not open PRs or
issues — the audit log is the deliverable.
PROMPT
)"

  CLAUDE_LOG="$HIVE/logs/workspace-doc-sweep-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$(dirname "$CLAUDE_LOG")"
  if claude -p "$prompt" \
       --permission-mode acceptEdits \
       --add-dir "$CLAUDE_REPO" \
       --add-dir "$HIVE" \
       --append-system-prompt "You are doc-00-documentation in workspace audit-only mode. Produce a manifest, never delete or edit." \
       > "$CLAUDE_LOG" 2>&1; then
    emit "PROGRESS" "workspace audit complete (manifest=$WORKSPACE_AUDIT_LOG)"
  else
    rc=$?
    emit "BLOCKED" "claude -p exit $rc (see $CLAUDE_LOG)"
    # Mark the run as partial-failure so cron / pipeline-health-check sees
    # it (was previously dropped on the floor — falling through to exit 0
    # masked the failure entirely).
    EXIT_STATUS=2
  fi
else
  echo "[dry-run] would dispatch DOC-00 in workspace audit-only mode"
  emit "PROGRESS" "dry-run: skipped DOC-00 dispatch"
fi

emit "COMPLETE" "mode=$([ $DRY_RUN -eq 1 ] && echo dry-run || echo apply) exit_status=$EXIT_STATUS"
echo ""
echo "[workspace-doc-sweep] done (exit=$EXIT_STATUS)"
exit "$EXIT_STATUS"
