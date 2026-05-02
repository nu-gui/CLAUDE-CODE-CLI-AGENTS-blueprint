#!/usr/bin/env bash
# enforce-branch-protection.sh
#
# One-shot runbook for applying GitHub branch protection to `main` on
# ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint. Not wired to cron. Requires repo-admin gh
# auth — run manually, read the dry-run output first, then re-run without
# --dry-run to apply.
#
# Issue #50 (part of 24h-agent-ops sprint, Wave 5C).
#
# Per CLAUDE.md Branch Workflow: `main` is PRODUCTION. No direct commits
# or pushes — only merges via reviewed promotion PRs from `master`. This
# script encodes that policy as a GitHub branch protection rule.

set -euo pipefail

REPO="${BRANCH_PROTECT_REPO:-${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint}"
BRANCH="${BRANCH_PROTECT_BRANCH:-main}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=1 ;;
    --repo=*)    REPO="${arg#--repo=}" ;;
    --branch=*)  BRANCH="${arg#--branch=}" ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI not found" >&2; exit 10; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated" >&2; exit 11; }

# The exact protection spec — mirrors the #50 issue body.
read -r -d '' PROTECTION_JSON <<'JSON' || true
{
  "required_status_checks": {
    "strict": true,
    "contexts": []
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON

cat <<INTRO
enforce-branch-protection.sh
  repo:   $REPO
  branch: $BRANCH
  mode:   $([ "$DRY_RUN" -eq 1 ] && echo DRY-RUN || echo APPLY)

Policy being enforced:
  - require PR review (>=1 approving)
  - dismiss stale reviews on new push
  - strict status checks (branch must be up-to-date)
  - no force pushes
  - no branch deletions
  - admins ARE allowed to bypass (enforce_admins=false) — emergency hatch
INTRO

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "Would PUT /repos/$REPO/branches/$BRANCH/protection with:"
  echo "$PROTECTION_JSON" | python3 -m json.tool
  echo ""
  echo "Re-run without --dry-run to apply. Requires repo-admin gh auth."
  exit 0
fi

# Apply. gh api --input reads JSON from stdin; PUT is idempotent so re-runs
# are safe.
echo "$PROTECTION_JSON" | gh api \
  -X PUT "/repos/$REPO/branches/$BRANCH/protection" \
  --input -

echo ""
echo "Applied. Verifying..."
gh api "/repos/$REPO/branches/$BRANCH/protection" --jq '{
  required_status_checks,
  enforce_admins: .enforce_admins.enabled,
  required_pull_request_reviews,
  allow_force_pushes: .allow_force_pushes.enabled,
  allow_deletions: .allow_deletions.enabled
}'
