#!/usr/bin/env bash
# scripts/hive-issue-create.sh — thin wrapper around hive_issue_create_deduped
# (issue #184 — Layer-1 issue-dedup guardrail)
#
# Use this in agent prompts and scripts instead of calling `gh issue create`
# directly. It fuzzy-matches the proposed title against open issues with the
# same labels and skips creation when a near-duplicate is found (score >= threshold).
#
# Usage:
#   bash ~/.claude/scripts/hive-issue-create.sh <repo> <title> <body-or-file> <labels> [threshold]
#
# Args:
#   repo        — owner/name (e.g. ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint)
#   title       — proposed issue title
#   body-or-file— issue body as a literal string OR path to a file (auto-detected)
#   labels      — comma-separated label list (used to filter existing + label new)
#   threshold   — optional similarity threshold (default 0.6, range 0..1)
#
# Output:
#   stdout: "https://github.com/.../issues/N"  — newly created issue URL, OR
#           "DUPLICATE_OF=#N score=X.YY"        — skipped (near-duplicate exists)
#
# Exit: 0 always (dedup-skip is not an error).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_issue_create_deduped "$@"
