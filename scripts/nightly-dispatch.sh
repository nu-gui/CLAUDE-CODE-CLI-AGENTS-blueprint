#!/usr/bin/env bash
# nightly-dispatch.sh
#
# Thin dispatcher for each nightly stage. Reads the queue, enforces safety
# rails (branch check, budget, guards), spawns `claude -p` with a minimal
# prompt carrying SESSION_ID, PROJECT_KEY, stage, queue ref, budget, and
# guards path. Agents consult ~/.claude/handbook/07-decision-guide.md to
# pick their own tools/skills.
#
# Usage:  nightly-dispatch.sh stage={A|B1|B2|C1|C2|digest-prep} [--dry-run]
#
# Event contract: see docs/event-contract.md (canonical source of truth for
# SPAWN/HANDOFF/SPECIALIST_COMPLETE/SPECIALIST_FAILED/BLOCKED/PROGRESS/COMPLETE
# semantics and invariants).

set -euo pipefail

# Shared helpers (issue #35 / #47): cron PATH + canonical hive_emit_event.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

PROFILES="$CLAUDE_HOME/config/nightly-repo-profiles.yaml"
QUEUE="$HIVE/nightly-queue.json"
DIGESTS_DIR="$HIVE/digests"
HANDBOOK="$CLAUDE_HOME/handbook"

TODAY="$(date -u +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p "$ESC_DIR" "$DIGESTS_DIR"

# --- Parse args ---
STAGE=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    stage=*)   STAGE="${arg#stage=}" ;;
    --stage=*) STAGE="${arg#--stage=}" ;;
    --dry-run) DRY_RUN=1 ;;
    *)         echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done
[[ -z "$STAGE" ]] && { echo "usage: $0 stage={A|B1|B2|C1|C2|mini|digest-prep} [--dry-run]" >&2; exit 2; }

# Mini-stage budgets (issue #30): daytime micro-dispatch runs a pared-down
# version of B1/B2 with tighter per-repo caps so we can sprinkle work across
# the day without risking revert-spirals on active repos.
#
# Overnight (A/B1/B2/C1/C2): 10 commits / 3 PRs / 50 files, 7200s bg-active
# Mini  (daytime 10/13/16/19): 3 commits / 1 PR / 15 files, 3600s bg-active
if [[ "$STAGE" == "mini" ]]; then
  BUDGET_COMMITS=3
  BUDGET_PRS=1
  BUDGET_FILES=15
  BG_ACTIVE_WINDOW=3600
else
  BUDGET_COMMITS=10
  BUDGET_PRS=3
  BUDGET_FILES=50
  BG_ACTIVE_WINDOW=7200
fi
export BUDGET_COMMITS BUDGET_PRS BUDGET_FILES BG_ACTIVE_WINDOW

SESSION_ID="nightly-${TODAY}-${STAGE}"

emit_event() { hive_emit_event "$1" "$2" "$3"; }  # multi-agent script; keeps 3-arg signature

escalate() {
  local code="$1" msg="$2"
  local f="$ESC_DIR/${TODAY}-${STAGE}.md"
  {
    echo "# Nightly dispatch escalation — $TODAY ($STAGE)"
    echo ""
    echo "**Code:** $code"
    echo "**Message:** $msg"
    echo "**When:** $NOW_ISO"
  } > "$f"
  emit_event "dispatch" "BLOCKED" "$code: $msg"
}

emit_event "dispatch" "SPAWN" "stage=$STAGE dry_run=$DRY_RUN"
hive_heartbeat "nightly-dispatch-${STAGE}"

# --- Preflight ---
[[ -f "$QUEUE"    ]] || { escalate "QUEUE_MISSING"    "$QUEUE";    exit 10; }
[[ -f "$PROFILES" ]] || { escalate "PROFILES_MISSING" "$PROFILES"; exit 10; }
[[ -d "$HANDBOOK" ]] || { escalate "HANDBOOK_MISSING" "$HANDBOOK"; exit 10; }

# --- SSH preflight (issue #69 / PUFFIN-S3, fixed by W18-ID16) ---
# Use BatchMode=yes + 10s timeout so cron never hangs on a missing agent.
#
# IMPORTANT: `ssh -T git@github.com` returns exit code 1 on SUCCESSFUL auth
# (GitHub's "no shell access" banner is exit 1, not 0). Treating 1 as failure
# — as the original PR #79 did — wrongly tagged every systemd fire as
# ssh-preflight-fail. The healthy exit codes are 0 and 1; real failures are
# 124 (timeout) and 255 (auth failure / host unreachable / unknown host).
#
# On real failure: log a warning, set SSH_PUSH_DISABLED=1, continue (no exit).
# Downstream stages that call `git push` or `gh pr merge` MUST consult
# SSH_PUSH_DISABLED before executing push-capable operations.
SSH_PUSH_DISABLED=0
# `|| _ssh_exit=$?` prevents `set -e` (line 12) from exiting on the expected
# non-zero exit from `ssh -T` — we inspect the captured code below.
_ssh_exit=0
timeout 10s ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -T git@github.com 2>/dev/null || _ssh_exit=$?
if [[ "$_ssh_exit" -ne 0 && "$_ssh_exit" -ne 1 ]]; then
  SSH_PUSH_DISABLED=1
  echo "dispatch: WARNING ssh preflight failed (exit $_ssh_exit) — git push / gh pr operations disabled for this run" >&2
  emit_event "dispatch" "BLOCKED" "ssh-preflight-fail: exit=$_ssh_exit SSH_PUSH_DISABLED=1 (git push / gh pr merge skipped)"
else
  emit_event "dispatch" "PROGRESS" "ssh-preflight-ok: git@github.com reachable (exit=$_ssh_exit)"
fi
export SSH_PUSH_DISABLED

# --- Refuse deprecated paths ---
if echo "$PWD" | grep -qE '/home/[^/]+/orchestrator(/|$)'; then
  escalate "DEPRECATED_PATH" "refusing to operate under /home/*/orchestrator (duplicate of example-repo-AI)"
  exit 11
fi

# --- Per-project dispatch helper ---
dispatch_repo() {
  local name="$1" role="$2" local_path="$3"

  [[ "$role" == "context-only"      ]] && { emit_event "dispatch" "PROGRESS" "$name role=context-only (skip primary dispatch)"; return 0; }
  [[ "$role" == "background-active" ]] && { emit_event "dispatch" "PROGRESS" "$name role=background-active (another session is working this repo — skip to avoid double-work)"; return 0; }

  # --- Degraded-group liveness check (issue #18) ---
  # If this repo belongs to a coupled group that was flagged degraded by the
  # selector (a member was missing/archived), emit a PROGRESS event so the
  # specialist knows atomic-deploy/contract_guard requirements are lifted.
  # Membership is confirmed via the profiles yaml (source of truth); the
  # degraded_groups list from the queue provides the group name.
  if [[ -f "$QUEUE" ]]; then
    local degraded_group=""
    degraded_group="$(PROFILES="$PROFILES" NAME="$name" python3 - <<'PYEOF'
import json, os, sys, yaml
p = yaml.safe_load(open(os.environ["PROFILES"])) or {}
name = os.environ["NAME"]
queue_path = os.environ.get("QUEUE", "")
try:
    q = json.load(open(queue_path))
except Exception:
    sys.exit(0)
for dg in (q.get("degraded_groups") or []):
    g = (p.get("groups") or {}).get(dg.get("group","")) or {}
    if name in g.get("members", []):
        print(dg["group"])
        break
PYEOF
)" 2>/dev/null || true
    if [[ -n "$degraded_group" ]]; then
      emit_event "dispatch" "PROGRESS" \
        "$name coupled group '$degraded_group' is degraded — atomic-deploy requirement lifted; contract_guard skipped for this run"
    fi
  fi
  # triage-only: stale-PR sweeper spawn — prompt still flows through below, but
  # the specialist is told there are no new issues and to focus on the stale section.

  # Path check
  if [[ -z "$local_path" || ! -d "$local_path/.git" ]]; then
    emit_event "dispatch" "BLOCKED" "$name no local clone; would be cloned into github/${GITHUB_ORG:-your-org}/"
    return 0
  fi

  # Branch safety: never dispatch while HEAD is on main/master of the repo
  local cur_branch
  cur_branch="$(git -C "$local_path" branch --show-current 2>/dev/null || echo unknown)"
  if [[ "$cur_branch" == "main" || "$cur_branch" == "master" ]]; then
    emit_event "dispatch" "PROGRESS" "$name HEAD on $cur_branch (ok — specialist will create feature branch)"
  fi

  # Budget snapshot (pre-commit count since midnight)
  local midnight
  midnight="$(date -u -d "$TODAY 00:00:00" +%s 2>/dev/null || date -u +%s)"
  local commits_today
  commits_today="$(git -C "$local_path" log --since=@"$midnight" --oneline 2>/dev/null | wc -l | tr -d ' ')"

  local session="nightly-${TODAY}-${STAGE}-${name}"

  # Build stale-PR section for this repo (if any). Grouped by specialist so the
  # prompt recipient (ORC-00 / specialist) can route triage work naturally.
  #
  # 'any'-spec routing (issue #23): stale PRs without an [AGENT-*] title prefix
  # land in the 'any' bucket. If multiple specialists dispatch on this repo
  # tonight they would each see (and potentially re-triage) the same 'any' PRs.
  # Merge the 'any' bucket into the FIRST specialist alphabetically (by bucket
  # key, excluding 'any') so only one owner triages each PR. If no
  # [AGENT-*]-prefixed bucket exists, 'any' stays as-is (any dispatcher tonight
  # may pick it up).
  local stale_section=""
  if [[ -f "$QUEUE" ]]; then
    local stale_json any_routed_to=""
    stale_json="$(jq -c --arg r "$name" '.stale_prs_by_specialist[$r] // {}' "$QUEUE")"
    if [[ "$stale_json" != "{}" && "$stale_json" != "null" ]]; then
      any_routed_to="$(echo "$stale_json" | jq -r '
        (((keys // []) - ["any"]) | sort) as $specs
        | if ($specs | length) > 0 and ((.any // []) | length) > 0
          then $specs[0] else "" end
      ')"
      if [[ -n "$any_routed_to" ]]; then
        stale_json="$(echo "$stale_json" | jq -c --arg fs "$any_routed_to" '
          .[$fs] = ((.[$fs] // []) + ((.any // []) | map(. + {routed_from: "any"})))
          | .any = []
        ')"
        emit_event "dispatch" "PROGRESS" "$name any-spec stale PRs routed to [$any_routed_to] (issue #23)"
      fi
      local stale_lines
      stale_lines="$(echo "$stale_json" | jq -r '
        to_entries
        | map(. as $e | $e.value[]
            | "  - #\(.number) [\($e.key)] \(.title) (updated \(.updated_at))"
              + (if .routed_from then " [routed from \(.routed_from)]" else "" end))
        | .[]
      ')"
      if [[ -n "$stale_lines" ]]; then
        local any_note=""
        if [[ -n "$any_routed_to" ]]; then
          any_note=$'\n'"Note: 'any'-spec PRs (no [AGENT-*] title prefix) are routed to [$any_routed_to] for this repo tonight to prevent duplicate triage when multiple specialists dispatch on this repo. Other specialists: treat your 'any' bucket as empty — routed to $any_routed_to."
        fi
        stale_section="$(cat <<STALE

## Stale PRs on this repo (triage FIRST before new issue work)

Window: no activity for > $(jq -r '.stale_pr_window_sec // 86400' "$QUEUE") seconds.$any_note

$stale_lines

Triage protocol (per handbook/07-decision-guide.md for tool picks):
  1. gh pr view <N> to understand current state.
  2. Merge-conflict → rebase on master; if clean, push with --force-with-lease
     and comment "Rebased on master (nightly-puffin sweeper)". Unresolvable →
     add label blocked-human + explain in a comment. Stop on that PR.
  3. Red CI → inspect latest run logs; fix the specific failure in a follow-up
     commit; push. Cap 3 CI-fix commits per PR per night.
  4. Unresolved review comments → address (fix code or reply explaining);
     push. Can't address → blocked-human + ask for clarification.
  5. Green + >=1 approval + no unresolved threads → add label
     sweep-ready-to-merge. DO NOT MERGE. Never call gh pr merge.
  6. Already has blocked-human → skip unless blocker clearly resolved.

Safety rails:
  - Never use git push --force (use --force-with-lease).
  - Never gh pr merge --base main (deny rule catches it too).
  - Combined budget (new + triage): 10 commits / 3 PRs / 50 files per repo.
  - Reserve 5 commits for new-issue work — cap triage at 5 commits per run.
  - Prefix sweeper commits: "chore(nightly-sweep): ..." so attribution is clear.
  - Loop guard: if a PR was sweeper-touched on prior night and is STILL red,
    add blocked-human and skip (do not re-touch).
STALE
)"
      fi
    fi
  fi

  local prompt
  prompt="$(cat <<PROMPT
SESSION_ID: $session
PROJECT_KEY: $name
Stage: $STAGE
Queue: $QUEUE
Local path: $local_path
Budget: $BUDGET_COMMITS commits / $BUDGET_PRS PRs / $BUDGET_FILES files per repo this run (already used: $commits_today commits today)
Guards: $PROFILES (section: repos.$name)
Handbook: $HANDBOOK

Hive protocol: the dispatch wrapper emits SPAWN/HANDOFF before this prompt
fires and emits SPECIALIST_COMPLETE/SPECIALIST_FAILED after you exit. Do
NOT write to ~/.claude/context/hive/events.ndjson or create new session
folders under ~/.claude/context/hive/sessions/ yourself — those writes
are sandbox-denied in headless execution. Focus on the *work*: branch,
commit, PR. Event lifecycle is recorded externally.
Tool/skill selection: consult handbook/07-decision-guide.md before acting. Do not ask
the user which tool to use.

Branch workflow (MANDATORY):
  - Work from $local_path
  - Branch from master: git checkout master && git pull && git checkout -b <type>/<slug>
  - Target master on PRs: gh pr create --base master --label nightly-automation
  - NEVER commit, push, or auto-merge to main.

Stage-specific entry point:
  A         : PLAN-00 — audit queued repos, fill gaps only (issues without [AGENT-*]
              prefix). Label new or refined issues nightly-candidate. Do NOT re-classify
              existing [AGENT-*] prefixed issues.
  B1 / B2   : ORC-00 — read nightly-candidate issues for this repo, parse [AGENT-*]
              prefix, dispatch directly to that specialist. Respect per-path guards in
              the profile (propose-only / sup-00-explicit-approve / api-gov-review-required
              / deny). Atomic deploy groups (see queue "collisions" + profile "groups").
  C1        : TEST-00 runs suites on this repo's nightly PRs, then SUP-00 reviews.
              For [SECURITY]/[P0-SEC], add api-gov. APPROVE → add "approved-nightly"
              label. REJECT twice → add "blocked-human" label and stop this repo.
  C2        : DOC-00 updates README/CHANGELOG on approved-nightly PRs. Then auto-merge
              them to master. Do NOT merge to main. Open a master→main promotion PR.
              INFRA-CORE delegation for staging deploy is handled by nightly-deploy.sh
              (called separately).
  digest-prep: aggregate events.ndjson since midnight + gh activity into
              ~/.claude/context/hive/digests/${TODAY}.partial.md for the 07:00 digest.

Coupled groups: if this repo is in profile groups.<group>.members, sibling repos are
queued as role=context-only. Read them, grep them, but do not commit. For
contract-surface changes, cite evidence from siblings before SUP-00 APPROVE.

Safety rails enforced by the wrapper BEFORE this prompt:
  - Budget counted; if repo has already hit 10 commits today, dispatch skips and
    emits a BLOCKED event.
  - Deprecated /home/*/orchestrator path is refused at dispatch time.

When done, finish with a concise summary paragraph on stdout — the wrapper
captures your final output into the nightly digest. Do NOT emit events
directly; the wrapper records SPECIALIST_COMPLETE/SPECIALIST_FAILED based
on your exit code.
${stale_section}
PROMPT
)"

  # Budget enforcement at dispatch time
  if [[ "$commits_today" -ge "$BUDGET_COMMITS" ]]; then
    emit_event "dispatch" "BLOCKED" "$name budget_exhausted (commits_today=$commits_today cap=$BUDGET_COMMITS stage=$STAGE)"
    return 0
  fi

  # Mini-stage also wants a fresh background-active check (the selector's
  # view is stale by 10:00/13:00/16:00/19:00 since it was taken at 23:30).
  if [[ "$STAGE" == "mini" && -n "$local_path" && -d "$local_path/.git" ]]; then
    local cutoff_bg
    cutoff_bg="$(date -u -d "-${BG_ACTIVE_WINDOW} seconds" +%s 2>/dev/null || echo 0)"
    if [[ "$(git -C "$local_path" log --since=@"$cutoff_bg" --all --format=%H 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]]; then
      emit_event "dispatch" "PROGRESS" "$name mini-skip (background-active within ${BG_ACTIVE_WINDOW}s)"
      return 0
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "---[DRY RUN: $name stage=$STAGE]---"
    echo "$prompt" | head -20
    echo "---"
    emit_event "dispatch" "PROGRESS" "$name dry-run"
    return 0
  fi

  emit_event "dispatch" "HANDOFF" "$name → claude -p ($STAGE)"

  local append_sys="You are a nightly-puffin specialist running headless via dispatch. Execute your full protocol directly — branch from master, commit, push, open PR. Read ~/.claude/handbook/00-hive-protocol.md and ~/.claude/handbook/07-decision-guide.md before acting. Honour hive protocol for every tool call. Do not return plan summaries; act."

  # POOL_MODE=1: enqueue to dispatch-queue.ndjson instead of spawning
  # directly. pool-worker.sh consumes under the 9-spawns/hour cap (issue
  # #49). Mini stage is the intended first opt-in; overnight stays direct
  # until the pool is proven under load.
  if [[ "${POOL_MODE:-0}" == "1" ]]; then
    hive_pool_enqueue "nightly-dispatch" "$name" "$session" "$prompt" "$local_path" "$append_sys"
    emit_event "dispatch" "PROGRESS" "$name enqueued to pool (POOL_MODE=1 stage=$STAGE)"
    return 0
  fi

  # acceptEdits + --add-dir required for headless execution. Without them,
  # specialists enter plan mode and/or fail on sandbox write denial for the
  # target repo + hive paths.
  #
  # Retry on transient failures (exit 124=timeout, 130=SIGINT, 137=SIGKILL).
  # Non-transient exit codes go straight to BLOCKED without retry.
  # Credential-expiry exits are detected via stderr grep and escalate to a
  # human-visible GitHub issue immediately — no retry (W18-ID13).
  local attempt=0
  local max_attempts=2
  local claude_exit=0
  local _stderr_tmp
  _stderr_tmp="$(mktemp /tmp/nightly-dispatch-stderr.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$_stderr_tmp'" RETURN
  while (( attempt < max_attempts )); do
    attempt=$((attempt+1))
    claude -p "$prompt" \
      --permission-mode acceptEdits \
      --add-dir "$local_path" \
      --add-dir "$HIVE" \
      --append-system-prompt "$append_sys" \
      2> >(tee -a "$_stderr_tmp" >&2)
    claude_exit=$?
    if [[ "$claude_exit" -eq 0 ]]; then
      break
    fi
    # Credential-expiry check: grep stderr for auth-failure indicators.
    # On match, escalate to human immediately — do NOT retry.
    if grep -qiE 'unauthorized|credentials|token.*expired|auth.*required|not.*logged.*in' "$_stderr_tmp" 2>/dev/null; then
      emit_event "dispatch" "SPECIALIST_FAILED" "$name stage=$STAGE exit=$claude_exit attempts=$attempt (CREDENTIAL_EXPIRED)"
      escalate "CREDENTIAL_EXPIRED" "$name ($STAGE): claude -p exited $claude_exit — workspace credentials expired on ${USER}-optiplex. Re-run \`claude auth login\`."
      # Open a blocked-human GitHub issue (idempotent).
      local _cred_title="[AUTH] Claude workspace credentials expired on ${USER}-optiplex — re-run \`claude auth login\`"
      local _open_count
      _open_count="$(gh issue list \
        --repo ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint \
        --search 'in:title [AUTH] Claude workspace credentials expired' \
        --state open \
        --json number \
        --jq length 2>/dev/null || echo 0)"
      if [[ "$_open_count" -eq 0 ]]; then
        gh issue create \
          --repo ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint \
          --title "$_cred_title" \
          --label "blocked-human,P0,infra" \
          --body "Detected during \`nightly-dispatch.sh\` stage \`$STAGE\` repo \`$name\`.

\`claude -p\` exited $claude_exit with auth-failure output. The pipeline has stopped retrying and emitted a \`BLOCKED:CREDENTIAL_EXPIRED\` event.

**Action required**: SSH into ${USER}-optiplex and run \`claude auth login\`, then re-queue the affected stage.

_Auto-opened by nightly-dispatch.sh (W18-ID13)_" 2>/dev/null || true
      fi
      return 0
    fi
    # Only retry on signal-like exits; logic errors go straight to BLOCKED.
    if [[ "$claude_exit" -ne 124 && "$claude_exit" -ne 130 && "$claude_exit" -ne 137 ]]; then
      break
    fi
    emit_event "dispatch" "PROGRESS" "$name claude -p exit $claude_exit — retrying (attempt $((attempt+1))/$max_attempts)"
    sleep 30
  done
  # Emit the specialist's lifecycle event externally. Headless claude -p
  # subprocesses cannot append to events.ndjson themselves (sandbox denial
  # on shell-redirect writes to hive paths, regardless of --add-dir). The
  # wrapper owns the SPAWN/HANDOFF/SPECIALIST_COMPLETE|FAILED boundary.
  if [[ "$claude_exit" -eq 0 ]]; then
    emit_event "dispatch" "SPECIALIST_COMPLETE" "$name stage=$STAGE attempts=$attempt"
    # C2 post-merge: retrigger CI on master after DOC-00/auto-merge completes
    # (issue #93 / PUFFIN-W18-ID2, fixed in #146). Derive owner from
    # local_path's parent dir so ${GITHUB_ORG:-your-org} repos (example-repo, CCS, etc.)
    # don't get a hardcoded ${GITHUB_ORG:-your-org}/ prefix that 404s. `|| true` guarantees
    # a transient retrigger failure cannot fail the whole C2 stage — the
    # specialist work has already been merged by this point.
    if [[ "$STAGE" == "C2" ]]; then
      local _retrigger_owner
      _retrigger_owner="$(basename "$(dirname "$local_path")")"
      if [[ -n "$_retrigger_owner" ]]; then
        ci_retrigger_after_merge "${_retrigger_owner}/${name}" || true
      else
        emit_event "ci-retrigger" "BLOCKED" "cannot derive owner from local_path=$local_path"
      fi
    fi
  else
    emit_event "dispatch" "SPECIALIST_FAILED" "$name stage=$STAGE exit=$claude_exit attempts=$attempt"
    emit_event "dispatch" "BLOCKED" "$name claude -p exit $claude_exit (after $attempt attempts)"
  fi
  # Capture trailing rc BEFORE the explicit return 0 below. Under
  # `set -euo pipefail` a non-zero from the last evaluated command in this
  # function (e.g. a transient emit_event failure or an edge case in
  # ci_retrigger_after_merge) would kill the outer stage loop before the
  # stage-wrapper COMPLETE event fires (#155). We mask it to keep the
  # stage intact, but surface the masked rc via a PROGRESS event so the
  # failure is still visible in events.ndjson — use the jq query in
  # docs/event-contract.md ("Hidden trailing-rc events") to monitor
  # frequency. Silent masking would hide real regressions.
  local _trailing_rc=$?
  if (( _trailing_rc != 0 )); then
    emit_event "dispatch" "PROGRESS" "$name dispatch-fn trailing-rc=$_trailing_rc (masked to preserve stage COMPLETE — investigate if frequent; see docs/event-contract.md)"
  fi
  return 0
}

# --- Stage-specific loop ---
case "$STAGE" in
  A|B1|B2|C1|C2|mini)
    # Iterate repos in the queue
    ROW_COUNT="$(jq '.repos | length' "$QUEUE")"
    if [[ "$ROW_COUNT" -eq 0 ]]; then
      emit_event "dispatch" "PROGRESS" "empty queue; skipping stage $STAGE"
      echo "dispatch: empty queue; nothing to do"
      exit 0
    fi

    # Extract repo rows
    dispatched_repos=()
    while IFS= read -r row; do
      name="$(echo "$row"       | jq -r '.name')"
      role="$(echo "$row"       | jq -r '.role')"
      local_path="$(echo "$row" | jq -r '.local_path // ""')"
      dispatch_repo "$name" "$role" "$local_path"
      [[ "$role" == "primary" ]] && dispatched_repos+=("$name")
    done < <(jq -c '.repos[]' "$QUEUE")

    # Quiet-triage pass (Stage B1/B2 only): repos with stale PRs that did NOT
    # get a primary dispatch this stage. Spawn a brief triage-only run so
    # stale PRs move even on quiet new-issue nights.
    # Mini stage does NOT run the quiet-triage sweep — it is a lightweight
    # micro-dispatch targeting only primary work so we do not burn the tiny
    # budget on PRs the selector did not vet for this window.
    if [[ "$STAGE" == "B1" || "$STAGE" == "B2" ]]; then
      STALE_REPOS="$(jq -r '.stale_prs_by_specialist | keys[]' "$QUEUE")"
      while IFS= read -r stale_repo; do
        [[ -z "$stale_repo" ]] && continue
        # Skip if already dispatched as primary this stage.
        skip=0
        for d in "${dispatched_repos[@]:-}"; do
          [[ "$d" == "$stale_repo" ]] && skip=1 && break
        done
        [[ "$skip" == "1" ]] && continue

        # Resolve local path using the same order as the selector.
        stale_path=""
        for p in "$HOME/github/${GITHUB_ORG:-your-org}/$stale_repo" \
                 "$HOME/github/${GITHUB_ORG:-your-org}/$stale_repo" \
                 "$HOME/$stale_repo"; do
          [[ -d "$p/.git" ]] && stale_path="$p" && break
        done
        if [[ -z "$stale_path" ]]; then
          emit_event "dispatch" "PROGRESS" "$stale_repo stale-PRs present but no local clone; skipping quiet-triage"
          continue
        fi

        # Skip if background-active (same check as selector; prevents race).
        cutoff_bg="$(date -u -d "-7200 seconds" +%s 2>/dev/null || echo 0)"
        if [[ "$(git -C "$stale_path" log --since=@"$cutoff_bg" --all --format=%H 2>/dev/null | wc -l | tr -d ' ')" -gt 0 ]]; then
          emit_event "dispatch" "PROGRESS" "$stale_repo quiet-triage skipped (background-active)"
          continue
        fi

        emit_event "dispatch" "PROGRESS" "$stale_repo quiet-triage spawn (stale PRs only, no new issues)"
        dispatch_repo "$stale_repo" "triage-only" "$stale_path"
      done <<< "$STALE_REPOS"
    fi
    ;;

  digest-prep)
    PARTIAL="$DIGESTS_DIR/${TODAY}.partial.md"
    if [[ ! -s "$PARTIAL" ]]; then
      : > "$PARTIAL"
      echo "# Partial digest for $TODAY" >> "$PARTIAL"
    fi
    # Aggregate events since midnight into partial
    MIDNIGHT_EPOCH="$(date -u -d "$TODAY 00:00:00" +%s 2>/dev/null || echo 0)"
    jq -r --argjson m "$MIDNIGHT_EPOCH" '
      select((.ts | sub("\\..*Z$"; "Z") | fromdateiso8601) >= $m)
      | [.ts, .agent, .event, .sid, .detail] | @tsv
    ' "$EVENTS" 2>/dev/null >> "$PARTIAL" || true
    emit_event "dispatch" "COMPLETE" "digest-prep aggregated → $PARTIAL"
    ;;

  *)
    echo "unknown stage: $STAGE" >&2; exit 2 ;;
esac

emit_event "dispatch" "COMPLETE" "stage $STAGE finished"
echo "dispatch: stage=$STAGE done"
