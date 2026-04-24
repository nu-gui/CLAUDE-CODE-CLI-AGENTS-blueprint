#!/usr/bin/env bash
# nightly-deploy.sh
#
# Stack-specific staging deploys driven by nightly-repo-profiles.yaml.
# Called after Stage C2 (approved-nightly merges to master). Deploys the
# just-merged master of each repo touched tonight to staging.
#
# Never deploys to production (main). Opens a master→main promotion PR
# per repo (or per coupled group — atomic).
#
# Per profile groups.<g>.deploy_mode == atomic: deploy all or hold all.

set -euo pipefail

# Shared helpers: cron PATH, hive paths, hive_emit_event (issue #35).
# Wraps ~180 lines of once-duplicated boilerplate across 8 scripts.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

PROFILES="$CLAUDE_HOME/config/nightly-repo-profiles.yaml"
QUEUE="$HIVE/nightly-queue.json"

TODAY="$(date -u +%Y-%m-%d)"
SESSION_ID="nightly-${TODAY}-deploy"
HIVE_DEFAULT_AGENT="deploy"

# Thin per-script wrapper keeps call-sites unchanged: `emit_event EVENT DETAIL`
# still works, but now lands in the canonical hive_emit_event in lib/common.sh.
emit_event() { hive_emit_event "$HIVE_DEFAULT_AGENT" "$1" "$2"; }

emit_event "SPAWN" "staging deploy"
hive_heartbeat "nightly-deploy"

[[ -f "$QUEUE"    ]] || { emit_event "BLOCKED" "queue missing";    exit 10; }
[[ -f "$PROFILES" ]] || { emit_event "BLOCKED" "profiles missing"; exit 10; }

# --- Get touched repos (primary) from the queue ---
REPOS="$(jq -r '.repos[] | select(.role=="primary") | .name' "$QUEUE")"

# --- Group resolution: expand to coupled members + atomic check ---
export PROFILES
GROUPS_JSON="$(python3 - <<'PY'
import os, yaml, json
p = yaml.safe_load(open(os.environ["PROFILES"]))
out = {}
for gname, g in (p.get("groups") or {}).items():
    out[gname] = {
        "members": g.get("members", []),
        "deploy_mode": g.get("deploy_mode", "per-repo"),
    }
print(json.dumps(out))
PY
)"

# Map repo → group (if any)
repo_group() {
  local r="$1"
  echo "$GROUPS_JSON" | jq -r --arg r "$r" '
    to_entries[] | select(.value.members | index($r)) | .key
  ' | head -1
}

# Deploy one repo using profile-configured command
deploy_single() {
  local repo="$1"
  local deploy_kind deploy_cmd local_path
  # Path resolution via hive_resolve_local_path (lib/common.sh) — issue #152.
  # Handles yaml override + ${HOME} expansion + candidate fallback uniformly
  # with the other readers; no more per-script duplication of the logic.
  local_path="$(hive_resolve_local_path "$PROFILES" "$repo")"

  deploy_kind="$(REPO="$repo" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"]))
r = (p.get("repos") or {}).get(os.environ["REPO"]) or {}
d = r.get("deploy") or (p.get("defaults") or {}).get("deploy") or {}
print(d.get("kind","") or "")
')"
  deploy_cmd="$(REPO="$repo" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"]))
r = (p.get("repos") or {}).get(os.environ["REPO"]) or {}
d = r.get("deploy") or (p.get("defaults") or {}).get("deploy") or {}
print(d.get("command","") or "")
')"

  if [[ -z "$local_path" ]]; then
    emit_event "BLOCKED" "$repo preflight-no-local-path"
    return 1
  fi
  if [[ -z "$deploy_cmd" ]]; then
    emit_event "BLOCKED" "$repo preflight-no-deploy-command"
    return 1
  fi

  # Skip explicitly-flagged skip repos without error
  if [[ "$deploy_kind" == "skip" ]]; then
    emit_event "PROGRESS" "$repo deploy skipped (kind=skip by profile)"
    return 0
  fi

  emit_event "PROGRESS" "$repo deploy kind=$deploy_kind path=$local_path"

  # Preflight checks per deploy kind — fail fast with actionable BLOCKED reasons
  # rather than letting docker-compose emit cryptic errors deep in the deploy.
  case "$deploy_kind" in
    docker-compose)
      # Determine which compose file the deploy command references (default,
      # coolify, etc.) and verify it exists before running docker.
      compose_file="docker-compose.yml"
      if [[ "$deploy_cmd" == *"-f "* ]]; then
        compose_file="$(echo "$deploy_cmd" | sed -E 's/.*-f +([^ ]+).*/\1/')"
      fi
      if [[ ! -f "$local_path/$compose_file" ]]; then
        emit_event "BLOCKED" "$repo preflight-missing-compose-file ($compose_file not found in $local_path)"
        return 1
      fi
      # Parse the compose file for `env_file` references and verify each exists.
      # Handles all three Compose syntaxes via python+yaml (regex can't reliably
      # parse indented block lists — the old grep approach missed form #3):
      #   1. Inline scalar:  env_file: .env
      #   2. Flow list:      env_file: [.env, .env.local]
      #   3. Block list:     env_file:
      #                        - .env
      #                        - path: .env.local
      #                          required: false   ← skipped (required=false)
      # If PyYAML is unavailable the python script prints "__NO_YAML__" so the
      # shell can emit BLOCKED: preflight-no-yaml-parser rather than silently
      # passing (which would let docker-compose fail later with a cryptic error).
      missing_envs=()
      _env_file_no_parser=0
      while IFS= read -r envref; do
        [[ -z "$envref" ]] && continue
        if [[ "$envref" == "__NO_YAML__" ]]; then
          _env_file_no_parser=1
          continue
        fi
        if [[ "$envref" = /* ]]; then
          envpath="$envref"
        else
          envpath="$local_path/$envref"
        fi
        [[ ! -f "$envpath" ]] && missing_envs+=("$envref")
      done < <(COMPOSE="$local_path/$compose_file" python3 - <<'PY' 2>/dev/null
import os, sys
try:
    import yaml
except Exception:
    print("__NO_YAML__")
    sys.exit(0)
try:
    with open(os.environ["COMPOSE"]) as f:
        doc = yaml.safe_load(f) or {}
except Exception:
    sys.exit(0)
for svc in (doc.get("services") or {}).values():
    if not isinstance(svc, dict):
        continue
    ef = svc.get("env_file")
    if ef is None:
        continue
    items = ef if isinstance(ef, list) else [ef]
    for item in items:
        if isinstance(item, str):
            print(item)
        elif isinstance(item, dict):
            # Long-form: {path: .env, required: true}
            # Only flag missing when required != false (default true).
            required = item.get("required", True)
            if required and item.get("path"):
                print(item["path"])
PY
)
      if [[ "$_env_file_no_parser" -eq 1 ]]; then
        emit_event "BLOCKED" "$repo preflight-no-yaml-parser (python3+yaml unavailable; cannot verify env_file entries)"
        return 1
      fi
      if [[ "${#missing_envs[@]}" -gt 0 ]]; then
        emit_event "BLOCKED" "$repo preflight-missing-env-files (${missing_envs[*]})"
        return 1
      fi
      ;;
    kamailio-reload)
      # No preflight — systemctl reports its own errors clearly
      :
      ;;
  esac

  # Grace window (seconds) before health-checking containers or services.
  # Override via DEPLOY_HEALTH_GRACE_SEC env var (default 30).
  local grace_sec="${DEPLOY_HEALTH_GRACE_SEC:-30}"

  local deploy_exit=0
  (
    cd "$local_path"
    git fetch --quiet origin
    git checkout master
    git pull --ff-only origin master
    eval "$deploy_cmd"
  ) || deploy_exit=$?

  if [[ "$deploy_exit" -ne 0 ]]; then
    emit_event "BLOCKED" "$repo deploy FAILED (exit $deploy_exit)"
    return 1
  fi

  # --- Post-deploy health check ---
  case "$deploy_kind" in
    docker-compose)
      # Wait for containers to settle, then verify all services are healthy/running.
      emit_event "PROGRESS" "$repo post-deploy health check (grace=${grace_sec}s)"
      sleep "$grace_sec"

      # docker compose ps --format json outputs one JSON object per line (v2 format).
      local ps_output failed_services=() service_states=""
      ps_output="$(cd "$local_path" && docker compose ps --format json 2>/dev/null)" || {
        emit_event "BLOCKED" "$repo health-check-failed (docker compose ps error)"
        return 1
      }

      # Parse each line: accumulate service states and flag non-running services.
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local svc_name svc_state
        svc_name="$(printf '%s' "$line" | jq -r '.Name // .Service // "unknown"' 2>/dev/null)"
        svc_state="$(printf '%s' "$line" | jq -r '.State // .Status // "unknown"' 2>/dev/null)"
        # Emit per-service status for morning digest.
        emit_event "PROGRESS" "$repo service=$svc_name state=$svc_state"
        service_states+="${svc_name}=${svc_state} "
        # Anything that isn't running/healthy is a failure.
        case "$svc_state" in
          running|healthy) : ;;
          *) failed_services+=("$svc_name($svc_state)") ;;
        esac
      done <<< "$ps_output"

      if [[ "${#failed_services[@]}" -gt 0 ]]; then
        local failed_list
        failed_list="$(IFS=,; echo "${failed_services[*]}")"
        emit_event "BLOCKED" "$repo deploy-unhealthy services=$failed_list"
        return 1
      fi

      # All services healthy — fall through to deploy OK.
      ;;

    kamailio-reload)
      # After a kamailio reload, verify the service is still active.
      emit_event "PROGRESS" "$repo post-reload kamailio health check"
      sleep "$grace_sec"

      local kam_state
      kam_state="$(systemctl is-active kamailio 2>/dev/null || echo "unknown")"
      emit_event "PROGRESS" "$repo kamailio state=$kam_state"
      if [[ "$kam_state" != "active" ]]; then
        emit_event "BLOCKED" "$repo deploy-unhealthy kamailio state=$kam_state (expected active)"
        return 1
      fi
      ;;
  esac

  emit_event "PROGRESS" "$repo deploy OK"

  # Open master→main promotion PR (never merge it)
  local default_branch
  default_branch="$(gh repo view "${GITHUB_ORG:-your-org}/$repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo master)"

  # SSH preflight gate (#80 / PUFFIN-S3a): if nightly-dispatch.sh preflight
  # set SSH_PUSH_DISABLED=1, skip the promotion PR cleanly rather than letting
  # gh fail on push. Only affects automation path — ad-hoc invocations not
  # downstream of dispatch won't have the env var set and proceed normally.
  if [[ "${SSH_PUSH_DISABLED:-0}" == "1" ]]; then
    emit_event "PROGRESS" "$repo promotion PR skipped (SSH_PUSH_DISABLED=1)"
    return 0
  fi

  # Only promote if main exists and differs
  if gh api "repos/${GITHUB_ORG:-your-org}/$repo/branches/main" >/dev/null 2>&1; then
    existing_pr="$(gh pr list -R "${GITHUB_ORG:-your-org}/$repo" --state open --base main --head master --json number -q '.[0].number' 2>/dev/null || echo "")"
    if [[ -z "$existing_pr" ]]; then
      gh pr create -R "${GITHUB_ORG:-your-org}/$repo" --base main --head master \
        --title "[promotion] master → main ($TODAY)" \
        --body "Nightly-puffin promotion PR. Deployed to staging on $TODAY. Do not merge until reviewed." \
        --label "nightly-promotion" 2>/dev/null \
        && emit_event "PROGRESS" "$repo promotion PR opened" \
        || emit_event "PROGRESS" "$repo promotion PR skipped (nothing to promote or label missing)"
    else
      emit_event "PROGRESS" "$repo promotion PR already open: #$existing_pr"
    fi
  fi
}

# --- Atomic group deploys first ---
declare -A handled_in_group
for gname in $(echo "$GROUPS_JSON" | jq -r 'keys[]'); do
  members="$(echo "$GROUPS_JSON" | jq -r --arg g "$gname" '.[$g].members[]')"
  mode="$(   echo "$GROUPS_JSON" | jq -r --arg g "$gname" '.[$g].deploy_mode')"
  # Is any member in tonight's touched-repos list?
  any_touched=0
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if grep -qxF "$m" <<< "$REPOS"; then any_touched=1; break; fi
  done <<< "$members"

  [[ "$any_touched" -eq 0 ]] && continue

  if [[ "$mode" != "atomic" ]]; then
    continue  # handled per-repo below
  fi

  emit_event "PROGRESS" "group=$gname atomic deploy (members: $(echo "$members" | tr '\n' ' '))"

  # All members must be deploy-ready: no blocker events for them tonight.
  blocked=0
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if jq -e --arg d "${TODAY}T00:00:00Z" --arg m "$m" '
      select(.agent != null)
      | select(.event == "BLOCKED")
      | select(.detail | tostring | startswith($m + " "))
    ' "$EVENTS" >/dev/null 2>&1; then
      blocked=1
      emit_event "BLOCKED" "group=$gname member=$m had BLOCKED event; holding whole group"
      break
    fi
  done <<< "$members"

  if [[ "$blocked" -eq 1 ]]; then
    emit_event "BLOCKED" "group=$gname HOLD (atomic: deploy all or none)"
    while IFS= read -r m; do
      [[ -n "$m" ]] && handled_in_group[$m]=1
    done <<< "$members"
    continue
  fi

  # Deploy all members; if any fails, mark the whole group as BLOCKED
  group_ok=1
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    if ! deploy_single "$m"; then group_ok=0; fi
    handled_in_group[$m]=1
  done <<< "$members"

  if [[ "$group_ok" -eq 1 ]]; then
    emit_event "PROGRESS" "group=$gname atomic deploy COMPLETE"
  else
    emit_event "BLOCKED" "group=$gname atomic deploy PARTIAL FAILURE — review required"
  fi
done

# --- Per-repo deploys (skip any handled by a group) ---
deploy_total=0
deploy_ok=0
deploy_failed=0
while IFS= read -r r; do
  [[ -z "$r" ]] && continue
  if [[ "${handled_in_group[$r]:-0}" == "1" ]]; then continue; fi
  deploy_total=$((deploy_total+1))
  if deploy_single "$r"; then
    deploy_ok=$((deploy_ok+1))
  else
    deploy_failed=$((deploy_failed+1))
  fi
done <<< "$REPOS"

# COMPLETE event now reports totals so the morning digest can distinguish
# "deploy stage ran through" from "everything actually deployed".
emit_event "COMPLETE" "deploy stage done — total=$deploy_total ok=$deploy_ok failed=$deploy_failed"
echo "deploy: total=$deploy_total ok=$deploy_ok failed=$deploy_failed"
