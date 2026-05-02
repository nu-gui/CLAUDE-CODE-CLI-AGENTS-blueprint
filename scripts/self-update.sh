#!/usr/bin/env bash
# scripts/self-update.sh
#
# Pulls origin/master into ~/.claude before each nightly stage so that script
# changes merged on GitHub reach the cron runtime the same day. Surfaced as
# the root cause of PR #199 (rebase-queue-depth) silently never running for
# 2 days after merge: the local working tree was 1 commit behind origin/master
# and cron executes the on-disk script, not the remote.
#
# Behaviour:
#   - Refuses to operate if the working tree has uncommitted modifications to
#     any tracked script under scripts/ or config/ (humans may be mid-edit).
#   - Refuses to operate if local has commits ahead of origin/master.
#   - Otherwise runs `git fetch && git merge --ff-only origin/master`.
#
# Idempotent: when local == remote it's a no-op.
# Cron-safe: emits a single PROGRESS or BLOCKED event per fire so the digest
# can spot drift between deploys and what the cron actually executes.
#
# Exit codes:
#   0  fast-forward succeeded or already up to date
#   1  refused to update (uncommitted state) — emitted BLOCKED
#   2  fetch/merge failed — emitted BLOCKED

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
hive_cron_path

CLAUDE_REPO="${CLAUDE_REPO:-$HOME/.claude}"
SID="self-update-$(date -u +%Y%m%dT%H%M%SZ)"

emit() { SID="$SID" hive_emit_event "self-update" "$1" "$2"; }

cd "$CLAUDE_REPO"

# Refuse if current branch has commits ahead of origin/master — operator may
# be mid-flight with an unpushed feature branch.
local_head="$(git rev-parse HEAD 2>/dev/null || echo "")"
if [[ -z "$local_head" ]]; then
  emit "BLOCKED" "could-not-resolve-HEAD in $CLAUDE_REPO"
  exit 2
fi

if ! git fetch --quiet origin master 2>/dev/null; then
  emit "BLOCKED" "fetch-failed (network or auth)"
  exit 2
fi

remote_head="$(git rev-parse origin/master 2>/dev/null || echo "")"
if [[ "$local_head" == "$remote_head" ]]; then
  emit "PROGRESS" "already-up-to-date local=$local_head"
  exit 0
fi

# Reject divergence (local has commits not in remote — a feature branch tracking
# master, e.g.). A fast-forward is only safe when local is strictly behind.
if ! git merge-base --is-ancestor HEAD origin/master 2>/dev/null; then
  emit "BLOCKED" "divergent-history: local=$local_head not an ancestor of remote=$remote_head"
  exit 1
fi

# If tracked scripts/config have uncommitted edits (e.g. the example-repo v6
# event-wiring patches that live as long-lived local mods), stash them first,
# fast-forward, then pop. Stashing transparently preserves the patches across
# the merge. If pop conflicts (because upstream changed the same lines the
# patch touched), self-update emits BLOCKED — operator resolves manually.
stashed=0
if ! git diff --quiet -- scripts/ config/ 2>/dev/null \
     || ! git diff --cached --quiet -- scripts/ config/ 2>/dev/null; then
  if git stash push --quiet -m "self-update-auto-stash-$(date -u +%s)" \
        -- scripts/ config/ 2>/dev/null; then
    stashed=1
  else
    emit "BLOCKED" "stash-failed — cannot safely fast-forward over local mods"
    exit 1
  fi
fi

if ! git merge --ff-only --quiet origin/master 2>/dev/null; then
  if [[ "$stashed" -eq 1 ]]; then
    git stash pop --quiet 2>/dev/null || true
  fi
  emit "BLOCKED" "ff-merge-failed local=$local_head remote=$remote_head"
  exit 2
fi

new_head="$(git rev-parse HEAD)"

# Restore stashed local mods. If pop conflicts, the merge has already
# succeeded — surface the conflict but don't roll back the update.
if [[ "$stashed" -eq 1 ]]; then
  if ! git stash pop --quiet 2>/dev/null; then
    emit "BLOCKED" "stash-pop-conflict $local_head → $new_head — local mods conflict with upstream; resolve manually"
    echo "[self-update] WARN: ff-merge succeeded but stash pop conflicted — resolve manually" >&2
    exit 0  # update succeeded; conflict is the operator's to handle
  fi
  emit "PROGRESS" "fast-forward $local_head → $new_head (local mods preserved via stash)"
else
  emit "PROGRESS" "fast-forward $local_head → $new_head"
fi
echo "[self-update] $local_head → $new_head"
exit 0
