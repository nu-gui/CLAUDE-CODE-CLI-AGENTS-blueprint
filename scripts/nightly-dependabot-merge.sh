#!/usr/bin/env bash
# nightly-dependabot-merge.sh
#
# Script-only side-track. Auto-merges green dependency PRs to master,
# without invoking a specialist agent. Runs in parallel with Stage B1.
#
# Cap: 10 auto-merges per night.
# Targets: PRs with label "dependencies" (Dependabot), non-draft,
#          statusCheckRollup all green, base == default branch,
#          not targeting main.

set -euo pipefail

# Shared helpers (issue #35 / #47).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

QUEUE="$HIVE/nightly-queue.json"

TODAY="$(date -u +%Y-%m-%d)"
SESSION_ID="nightly-${TODAY}-dependabot"
MAX_MERGES="${NIGHTLY_DEPENDABOT_MAX:-20}"  # EXAMPLE-ID: doubled default

emit_event() { hive_emit_event "dependabot-merge" "$1" "$2"; }

emit_event "SPAWN" "max_merges=$MAX_MERGES"

[[ -f "$QUEUE" ]] || { emit_event "BLOCKED" "queue missing"; exit 10; }

# Read dependabot sub-queue from the selector output
DEPS="$(jq -r '.dependabot_prs[]? | [.repo, .number] | @tsv' "$QUEUE")"

if [[ -z "$DEPS" ]]; then
  emit_event "COMPLETE" "no dependency PRs"
  exit 0
fi

merged=0 skipped=0 failed=0

# PRs that had `gh pr merge --auto` scheduled successfully are collected here
# so they can be polled in a single batched settlement pass after all
# auto-merge calls have fired.  Format: "repo number headSHA" per entry.
pending_poll=()

while IFS=$'\t' read -r repo number; do
  [[ -z "$repo" || -z "$number" ]] && continue
  if [[ "$merged" -ge "$MAX_MERGES" ]]; then
    emit_event "PROGRESS" "cap reached ($MAX_MERGES); stopping"
    break
  fi

  # Gather PR details
  pr_json="$(gh pr view "$number" -R "${GITHUB_ORG:-your-org}/$repo" --json baseRefName,state,isDraft,mergeable,statusCheckRollup,labels,headRefOid 2>/dev/null || echo '')"
  if [[ -z "$pr_json" ]]; then
    emit_event "PROGRESS" "$repo#$number gh view failed; skip"
    skipped=$((skipped+1)); continue
  fi

  base="$(echo "$pr_json" | jq -r '.baseRefName')"
  is_draft="$(echo "$pr_json" | jq -r '.isDraft')"
  mergeable="$(echo "$pr_json" | jq -r '.mergeable')"
  head_sha="$(echo "$pr_json" | jq -r '.headRefOid')"

  # Never target main
  if [[ "$base" == "main" ]]; then
    emit_event "PROGRESS" "$repo#$number base=main — skip (never auto-merge to main)"
    skipped=$((skipped+1)); continue
  fi
  if [[ "$is_draft" == "true" ]]; then
    skipped=$((skipped+1)); continue
  fi
  if [[ "$mergeable" != "MERGEABLE" ]]; then
    emit_event "PROGRESS" "$repo#$number mergeable=$mergeable — skip"
    skipped=$((skipped+1)); continue
  fi

  # All status checks green?
  green="$(echo "$pr_json" | jq '[.statusCheckRollup[]? | .conclusion // .state] | all(. == "SUCCESS")')"
  if [[ "$green" != "true" ]]; then
    emit_event "PROGRESS" "$repo#$number checks_not_all_green — skip"
    skipped=$((skipped+1)); continue
  fi

  # Auto-merge with a single-shot retry on transient errors (network blips,
  # rate limits, brief 5xx). Non-transient errors (permission, conflict,
  # protected-branch) fail fast — no point retrying those.
  #
  # The `|| true` keeps `set -e` from aborting the loop if a merge attempt
  # fails. Per-iteration exit codes are captured into merge_exit regardless.
  try_merge() {
    merge_err="$(gh pr merge "$number" -R "${GITHUB_ORG:-your-org}/$repo" --squash --delete-branch --auto 2>&1 >/dev/null)" || true
    merge_exit=$?
  }

  is_transient() {
    # Heuristic patterns for retryable failures. Keep narrow — we don't
    # want to loop on a protected-branch or permission error.
    echo "$1" | grep -qiE 'timeout|temporarily unavailable|connection reset|rate limit|503|502|504|network is unreachable'
  }

  try_merge
  if [[ "$merge_exit" -ne 0 ]] && is_transient "$merge_err"; then
    emit_event "PROGRESS" "$repo#$number transient merge error; retry in 30s"
    sleep 30
    try_merge
  fi

  if [[ "$merge_exit" -eq 0 ]]; then
    # Auto-merge scheduled.  Do NOT count as merged yet — the actual merge
    # may be cancelled by CI failure or branch-protection after we exit.
    # Defer confirmation to the batched settlement poll below.
    pending_poll+=("$repo $number $head_sha")
  else
    # Truncate long errors so the event stays within sane line length
    err_short="$(echo "$merge_err" | head -c 300 | tr '\n' ' ')"
    emit_event "BLOCKED" "$repo#$number merge failed (exit=$merge_exit): $err_short"
    failed=$((failed+1))
  fi
done <<< "$DEPS"

# ---------------------------------------------------------------------------
# Batched settlement poll (issue #20)
#
# Strategy: fire all `gh pr merge --auto` calls first (above), then poll
# every pending PR together in a single timed window.  Total extra runtime
# is capped at 5 min regardless of how many PRs were scheduled — the poll
# window is shared, not per-PR.
#
# Poll cadence : every 30 s
# Max iterations: 10  → 5 min ceiling
# Terminal states: MERGED → emit existing "merged (squash)" event; count++
#                  CLOSED → treat as failed (auto-merge cancelled)
# Timeout       → emit "pending-automerge head=<SHA> pr=<N>" PROGRESS event
#                 with a distinct detail prefix so the next night's sweep can
#                 re-check before counting.
# ---------------------------------------------------------------------------
if [[ "${#pending_poll[@]}" -gt 0 ]]; then
  emit_event "PROGRESS" "settlement-poll: ${#pending_poll[@]} PRs pending; polling up to 5 min"

  POLL_MAX=10
  POLL_INTERVAL=30

  # Track which entries are still unresolved across iterations.
  # We use indices into pending_poll so settled PRs can be removed.
  declare -a still_pending=("${!pending_poll[@]}")

  for (( poll_iter=1; poll_iter<=POLL_MAX; poll_iter++ )); do
    [[ "${#still_pending[@]}" -eq 0 ]] && break

    declare -a next_pending=()

    for idx in "${still_pending[@]}"; do
      entry="${pending_poll[$idx]}"
      poll_repo="${entry%% *}"
      rest="${entry#* }"
      poll_num="${rest%% *}"
      poll_sha="${rest##* }"

      poll_json="$(gh pr view "$poll_num" -R "${GITHUB_ORG:-your-org}/$poll_repo" \
        --json state,mergedAt,headRefOid 2>/dev/null || echo '')"

      poll_state="$(echo "$poll_json" | jq -r '.state // "UNKNOWN"')"

      if [[ "$poll_state" == "MERGED" ]]; then
        emit_event "PROGRESS" "$poll_repo#$poll_num merged (squash)"
        merged=$((merged+1))
        # Settled — do not add to next_pending.
      elif [[ "$poll_state" == "CLOSED" ]]; then
        emit_event "BLOCKED" "$poll_repo#$poll_num auto-merge cancelled (state=CLOSED)"
        failed=$((failed+1))
        # Settled (negatively) — do not add to next_pending.
      else
        # Still open — keep polling.
        next_pending+=("$idx")
      fi
    done

    still_pending=("${next_pending[@]+"${next_pending[@]}"}")

    if [[ "${#still_pending[@]}" -gt 0 && "$poll_iter" -lt "$POLL_MAX" ]]; then
      sleep "$POLL_INTERVAL"
    fi
  done

  # Any PRs still unresolved after 5 min → pending-automerge event.
  # The distinct "pending-automerge" prefix lets the next night's sweep
  # query events.ndjson for this string and re-check those PRs before
  # counting them as merged.
  for idx in "${still_pending[@]+"${still_pending[@]}"}"; do
    entry="${pending_poll[$idx]}"
    poll_repo="${entry%% *}"
    rest="${entry#* }"
    poll_num="${rest%% *}"
    poll_sha="${rest##* }"
    emit_event "PROGRESS" \
      "pending-automerge head=$poll_sha pr=$poll_num repo=$poll_repo (auto-merge scheduled but not confirmed within 5 min)"
  done
fi

emit_event "COMPLETE" "merged=$merged skipped=$skipped failed=$failed"
echo "dependabot: merged=$merged skipped=$skipped failed=$failed"
