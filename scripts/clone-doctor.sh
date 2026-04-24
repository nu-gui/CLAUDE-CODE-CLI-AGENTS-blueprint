#!/bin/bash
#
# clone-doctor.sh
# USAGE_START
# Clone Doctor — verify ~/.claude (live runtime) and a working clone of this
# repo (e.g. ~/github/${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint) are in sync on master.
#
# Background: this repo is intentionally checked out twice on ${USER}-optiplex —
# once as ~/.claude/ (where Claude Code reads config) and once under ~/github/
# for clean PR/branch work. The .gitignore keeps runtime state out of git, so
# the two clones should have byte-identical tracked content whenever both are
# on master. This script is the guard against drift.
#
# Usage: clone-doctor.sh [--fix] [--quiet]
#   --fix    fast-forward both clones to origin/master when safe (both on
#            master, clean tree, no local commits ahead). Never force-updates
#            and never touches feature branches.
#   --quiet  only print on drift or error (useful for cron/wrappers)
#
# Exit codes:
#   0 — both clones in sync
#   1 — drift detected (or --fix ran but could not reconcile everything)
#   2 — clone missing, remote mismatch, or fetch/git error
#
# Configuration (env vars, all optional):
#   CLAUDE_DIR       default: $HOME/.claude
#   REPO_DIR         default: $HOME/github/${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint
#   EXPECTED_REMOTE  default: git@github.com:${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint.git
#
# Detached-HEAD states in either clone are reported as branch "(detached
# HEAD)" and skipped by --fix (fast-forward requires an attached master).
# USAGE_END
#

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
REPO_DIR="${REPO_DIR:-$HOME/github/${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint}"
EXPECTED_REMOTE="${EXPECTED_REMOTE:-git@github.com:${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint.git}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FIX_MODE=0
QUIET=0

for arg in "$@"; do
  case "$arg" in
    --fix)   FIX_MODE=1 ;;
    --quiet) QUIET=1 ;;
    --help|-h)
      sed -n '/^# USAGE_START$/,/^# USAGE_END$/{//!p}' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { [[ $QUIET -eq 1 ]] || echo -e "$*"; }
warn() { echo -e "$*" >&2; }

# Returns 0 if the clone is healthy enough to inspect, else 2.
# Populates globals: ${name}_BRANCH ${name}_HEAD ${name}_DIRTY ${name}_BEHIND ${name}_AHEAD
inspect_clone() {
  local name="$1" dir="$2"

  if [[ ! -d "$dir" ]]; then
    warn "${RED}✗${NC} $name: directory missing: $dir"
    return 2
  fi
  if [[ ! -d "$dir/.git" ]]; then
    warn "${RED}✗${NC} $name: not a git repo: $dir"
    return 2
  fi

  local remote
  remote="$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")"
  if [[ "$remote" != "$EXPECTED_REMOTE" ]]; then
    warn "${RED}✗${NC} $name: remote mismatch"
    warn "    expected: $EXPECTED_REMOTE"
    warn "    got:      ${remote:-<none>}"
    return 2
  fi

  if ! git -C "$dir" fetch --quiet origin 2>/dev/null; then
    warn "${RED}✗${NC} $name: git fetch origin failed"
    return 2
  fi

  local branch head dirty_tracked untracked behind ahead
  branch="$(git -C "$dir" branch --show-current)"
  # Detached HEAD returns empty — make it explicit so fix_clone's
  # branch != "master" skip prints a readable reason rather than 'branch '''.
  branch="${branch:-(detached HEAD)}"
  head="$(git -C "$dir" rev-parse --short HEAD)"
  # Count tracked vs untracked separately. Only tracked modifications block
  # a fast-forward (--untracked-files=no), so that's what fix_clone checks.
  # Untracked files (excluding .gitignored) are reported for visibility only.
  dirty_tracked="$(git -C "$dir" status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  untracked="$(git -C "$dir" ls-files --others --exclude-standard | wc -l | tr -d ' ')"
  behind="$(git -C "$dir" rev-list --count HEAD..origin/master 2>/dev/null || echo 0)"
  ahead="$(git -C "$dir" rev-list --count origin/master..HEAD 2>/dev/null || echo 0)"

  say "${CYAN}──${NC} ${BOLD}$name${NC}: $dir"
  say "    branch: $branch   HEAD: $head"
  say "    vs origin/master: behind=$behind ahead=$ahead"
  if [[ "$dirty_tracked" -gt 0 ]]; then
    say "    ${YELLOW}⚠${NC} uncommitted tracked changes: $dirty_tracked file(s)"
  fi
  if [[ "$untracked" -gt 0 ]]; then
    say "    ${YELLOW}⚠${NC} untracked files (not gitignored): $untracked file(s)"
  fi

  printf -v "${name}_BRANCH"        '%s' "$branch"
  printf -v "${name}_HEAD"          '%s' "$(git -C "$dir" rev-parse HEAD)"
  printf -v "${name}_DIRTY_TRACKED" '%s' "$dirty_tracked"
  printf -v "${name}_UNTRACKED"     '%s' "$untracked"
  printf -v "${name}_BEHIND"        '%s' "$behind"
  printf -v "${name}_AHEAD"         '%s' "$ahead"
  return 0
}

# Fast-forward a clone if all safety conditions hold.
fix_clone() {
  local name="$1" dir="$2" branch="$3" dirty_tracked="$4" ahead="$5" behind="$6"

  if [[ "$branch" != "master" ]]; then
    say "    ${YELLOW}!${NC} skip $name: on '$branch', not master"
    return 0
  fi
  if [[ "$dirty_tracked" -ne 0 ]]; then
    say "    ${YELLOW}!${NC} skip $name: $dirty_tracked uncommitted tracked file(s) — commit or stash first"
    return 0
  fi
  if [[ "$ahead" -ne 0 ]]; then
    say "    ${YELLOW}!${NC} skip $name: $ahead local commit(s) ahead of master — PR them first"
    return 0
  fi
  if [[ "$behind" -eq 0 ]]; then
    say "    ${GREEN}✓${NC} $name: already up to date"
    return 0
  fi

  say "    ${CYAN}→${NC} fast-forwarding $name to origin/master"
  if git -C "$dir" pull --ff-only --quiet origin master; then
    say "    ${GREEN}✓${NC} $name: now at $(git -C "$dir" rev-parse --short HEAD)"
  else
    warn "    ${RED}✗${NC} $name: pull --ff-only failed"
    return 1
  fi
}

say "${BOLD}=== clone-doctor ===${NC}"

inspect_clone CLAUDE "$CLAUDE_DIR" || exit 2
inspect_clone REPO   "$REPO_DIR"   || exit 2

# shellcheck disable=SC2154  # set by inspect_clone via printf -v
if [[ "$CLAUDE_HEAD" == "$REPO_HEAD" ]]; then
  say ""
  say "${GREEN}✓${NC} both clones at same HEAD ($(git -C "$CLAUDE_DIR" rev-parse --short HEAD))"
  exit 0
fi

say ""
say "${RED}✗ DRIFT${NC}: .claude=$(git -C "$CLAUDE_DIR" rev-parse --short HEAD)  repo=$(git -C "$REPO_DIR" rev-parse --short HEAD)"

if [[ $FIX_MODE -eq 0 ]]; then
  say ""
  say "Re-run with ${BOLD}--fix${NC} to fast-forward both clones if they're on master + clean."
  exit 1
fi

say ""
say "${CYAN}--fix${NC}: attempting safe reconciliation"

fix_ok=0
fix_clone CLAUDE "$CLAUDE_DIR" "$CLAUDE_BRANCH" "$CLAUDE_DIRTY_TRACKED" "$CLAUDE_AHEAD" "$CLAUDE_BEHIND" || fix_ok=1
fix_clone REPO   "$REPO_DIR"   "$REPO_BRANCH"   "$REPO_DIRTY_TRACKED"   "$REPO_AHEAD"   "$REPO_BEHIND"   || fix_ok=1

claude_after="$(git -C "$CLAUDE_DIR" rev-parse HEAD)"
repo_after="$(git -C "$REPO_DIR" rev-parse HEAD)"

say ""
if [[ "$claude_after" == "$repo_after" && $fix_ok -eq 0 ]]; then
  say "${GREEN}✓${NC} sync complete ($(git -C "$CLAUDE_DIR" rev-parse --short HEAD))"
  exit 0
fi

say "${YELLOW}⚠${NC} drift remains after --fix (one or both clones needed manual attention)"
exit 1
