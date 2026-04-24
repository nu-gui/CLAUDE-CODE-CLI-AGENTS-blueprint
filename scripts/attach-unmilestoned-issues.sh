#!/usr/bin/env bash
# attach-unmilestoned-issues.sh
#
# Bulk-attach the current open sprint milestone to any pipeline-created issues
# (product-backlog or nightly-candidate label) that were created in the last
# 24 hours without a milestone.
#
# Nice-to-have helper for issue #94 (PUFFIN-W18-ID3). Run manually or add to
# cron after product-discovery.sh if you want retroactive milestone coverage.
#
# Usage:
#   attach-unmilestoned-issues.sh [--repo OWNER/NAME] [--hours N] [--dry-run]
#
# Defaults:
#   --repo  ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint
#   --hours 24
#
# Exit codes:
#   0  success (0 or more issues updated)
#   1  preflight failure (gh auth, jq missing, no open milestone)
#   2  argument error

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

# --- Defaults ---
REPO="${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint"
HOURS=24
DRY_RUN=0

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="$2";  shift 2 ;;
    --hours)   HOURS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1;  shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- Preflight ---
command -v gh  >/dev/null || { echo "gh CLI not found in PATH" >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found in PATH" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated" >&2; exit 1; }

# Resolve sprint milestone.
MILESTONE="$(hive_current_sprint_milestone "$REPO" 2>/dev/null || true)"
if [[ -z "$MILESTONE" ]]; then
  echo "No open sprint milestone found for $REPO — nothing to attach." >&2
  exit 0
fi
echo "Sprint milestone: $MILESTONE"

# --- Find unmilestoned pipeline issues created within the last $HOURS hours ---
# We query issues with product-backlog OR nightly-candidate label, no milestone,
# state=open. The GitHub search API supports created:>DATETIME.
SINCE="$(date -u -d "-${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
         { echo "date command error" >&2; exit 1; })"

echo "Searching $REPO for unmilestoned issues created since $SINCE..."

# Use gh issue list with --search for label filter + created:> filter.
ISSUES_JSON="$(gh_api_safe issue list \
  --repo "$REPO" \
  --state open \
  --limit 200 \
  --json number,title,milestone,labels,createdAt \
  --jq "[.[] | select(.milestone == null)
              | select(.createdAt >= \"$SINCE\")
              | select(.labels | map(.name) | any(. == \"product-backlog\" or . == \"nightly-candidate\"))]"
)" || {
  echo "gh issue list failed" >&2
  exit 1
}

COUNT="$(echo "$ISSUES_JSON" | jq 'length')"
echo "Found $COUNT unmilestoned pipeline issue(s) to attach."

if [[ "$COUNT" -eq 0 ]]; then
  echo "Nothing to do."
  exit 0
fi

# --- Attach milestone ---
ATTACHED=0
FAILED=0
while IFS= read -r row; do
  num="$(echo "$row" | jq -r '.number')"
  title="$(echo "$row" | jq -r '.title')"
  echo "  #$num: $title"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  DRY-RUN> gh issue edit $num --repo $REPO --milestone \"$MILESTONE\""
    ATTACHED=$((ATTACHED+1))
    continue
  fi
  if gh issue edit "$num" --repo "$REPO" --milestone "$MILESTONE" >/dev/null 2>&1; then
    echo "  -> attached milestone \"$MILESTONE\""
    ATTACHED=$((ATTACHED+1))
  else
    echo "  -> FAILED to attach milestone (skipping)" >&2
    FAILED=$((FAILED+1))
  fi
done < <(echo "$ISSUES_JSON" | jq -c '.[]')

echo "Done: attached=$ATTACHED failed=$FAILED dry_run=$DRY_RUN"
hive_emit_event "attach-unmilestoned-issues" "COMPLETE" \
  "repo=$REPO milestone=$MILESTONE attached=$ATTACHED failed=$FAILED dry_run=$DRY_RUN"
