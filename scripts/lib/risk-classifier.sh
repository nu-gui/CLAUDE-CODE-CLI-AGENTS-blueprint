#!/usr/bin/env bash
# scripts/lib/risk-classifier.sh — sourceable
#
# classify_pr_tier <repo> <pr_number>
#   → stdout JSON: {"tier": 0..4, "reason": "...", "diff_lines": N, "diff_files": M, "paths": [...], "verdict_inputs": {...}}
#   → exit 0 always (caller reads .tier from JSON)
#
# Default: tier 4 (always-human). Lower tiers require explicit positive match
# in config/governance-policy.yaml. Fail-safe by design — if any classifier
# step errors out (gh API down, malformed yaml), we return tier 4 + reason.

set -euo pipefail

GOVERNANCE_POLICY="${GOVERNANCE_POLICY:-$HOME/.claude/config/governance-policy.yaml}"

# --------------------------------------------------------------------------
# Internal: glob-match a path string against an array of fnmatch patterns
# --------------------------------------------------------------------------
_path_matches_any() {
  local path="$1"; shift
  local patterns=("$@")
  local pat
  for pat in "${patterns[@]}"; do
    [[ -z "$pat" ]] && continue
    # Convert ** to a permissive match. Use python fnmatch via single
    # invocation per call — fnmatch is the same model GitHub uses for
    # CODEOWNERS, so behaviour matches user expectations.
    PATTERN="$pat" P="$path" python3 -c '
import os, fnmatch, sys
pat = os.environ["PATTERN"]
p = os.environ["P"]
# Convert ** semantics: fnmatch already does * across path separators
# (which matches our intent better than gitignore semantics here — we
# WANT broad matching so guards can not be bypassed via subdirectories).
sys.exit(0 if fnmatch.fnmatch(p, pat) else 1)
' && return 0
  done
  return 1
}

# --------------------------------------------------------------------------
# classify_pr_tier — main entry point
# --------------------------------------------------------------------------
classify_pr_tier() {
  local repo="$1" pr="$2"
  if [[ -z "$repo" || -z "$pr" ]]; then
    printf '{"tier":4,"reason":"missing-args"}'
    return 0
  fi

  if [[ ! -f "$GOVERNANCE_POLICY" ]]; then
    printf '{"tier":4,"reason":"policy-file-missing path=%s"}' "$GOVERNANCE_POLICY"
    return 0
  fi

  # ---- Pull PR data
  local pr_json
  pr_json="$(gh pr view "$pr" --repo "$repo" \
    --json number,title,labels,additions,deletions,changedFiles,files,statusCheckRollup,mergeable,mergeStateStatus,baseRefName,author,reviewDecision \
    2>/dev/null)" || {
    printf '{"tier":4,"reason":"gh-pr-view-failed repo=%s pr=%s"}' "$repo" "$pr"
    return 0
  }

  local title labels additions deletions changedFiles files_list \
        mergeable merge_state base author check_rollup
  title="$(printf '%s' "$pr_json" | jq -r '.title // ""')"
  labels="$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")')"
  additions="$(printf '%s' "$pr_json" | jq -r '.additions // 0')"
  deletions="$(printf '%s' "$pr_json" | jq -r '.deletions // 0')"
  changedFiles="$(printf '%s' "$pr_json" | jq -r '.changedFiles // 0')"
  files_list="$(printf '%s' "$pr_json" | jq -r '[.files[].path] | join("\n")')"
  mergeable="$(printf '%s' "$pr_json" | jq -r '.mergeable // ""')"
  merge_state="$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""')"
  base="$(printf '%s' "$pr_json" | jq -r '.baseRefName // ""')"
  author="$(printf '%s' "$pr_json" | jq -r '.author.login // ""')"
  check_rollup="$(printf '%s' "$pr_json" | jq '.statusCheckRollup // []')"

  local diff_lines=$((additions + deletions))

  # ---- Step 1: always_human bright line — tier 4 if any path matches
  local always_human_paths
  mapfile -t always_human_paths < <(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
for path in (p.get("always_human") or {}).get("paths") or []:
    print(path)
' 2>/dev/null)

  # ---- Step 2: per-repo elevations — also tier 4 if any path matches
  local repo_short="${repo#*/}"
  local repo_elevations_to_4
  mapfile -t repo_elevations_to_4 < <(GOV="$GOVERNANCE_POLICY" REPO="$repo_short" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
overrides = ((p.get("per_repo_overrides") or {}).get(os.environ["REPO"]) or {}).get("elevate_paths") or []
for entry in overrides:
    if int(entry.get("tier", 0)) == 4:
        print(entry["path"])
' 2>/dev/null)

  while IFS= read -r touched_path; do
    [[ -z "$touched_path" ]] && continue
    if [[ ${#always_human_paths[@]} -gt 0 ]] \
       && _path_matches_any "$touched_path" "${always_human_paths[@]}"; then
      printf '{"tier":4,"reason":"always_human-path-match path=%s","diff_lines":%s,"diff_files":%s}' \
        "$touched_path" "$diff_lines" "$changedFiles"
      return 0
    fi
    if [[ ${#repo_elevations_to_4[@]} -gt 0 ]] \
       && _path_matches_any "$touched_path" "${repo_elevations_to_4[@]}"; then
      printf '{"tier":4,"reason":"per-repo-elevation path=%s repo=%s","diff_lines":%s,"diff_files":%s}' \
        "$touched_path" "$repo_short" "$diff_lines" "$changedFiles"
      return 0
    fi
  done <<< "$files_list"

  # ---- Step 3: Tier 1 candidacy — ALL match_all conditions must hold
  local t1_enabled
  t1_enabled="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
print("true" if (p.get("tier_1") or {}).get("enabled") else "false")
' 2>/dev/null)"
  if [[ "$t1_enabled" != "true" ]]; then
    printf '{"tier":4,"reason":"tier-1-not-enabled"}'
    return 0
  fi

  # 3a. labels_required
  local labels_required
  labels_required="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
labs = ((p.get("tier_1") or {}).get("match_all") or {}).get("labels_required") or []
print(",".join(labs))
' 2>/dev/null)"
  local lab
  IFS=',' read -ra _labs_req <<< "$labels_required"
  for lab in "${_labs_req[@]}"; do
    [[ -z "$lab" ]] && continue
    if ! printf '%s' "$labels" | grep -qF "$lab"; then
      printf '{"tier":4,"reason":"missing-label label=%s","diff_lines":%s,"diff_files":%s}' \
        "$lab" "$diff_lines" "$changedFiles"
      return 0
    fi
  done

  # 3b. title_pattern
  local title_pattern
  title_pattern="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
print(((p.get("tier_1") or {}).get("match_all") or {}).get("title_pattern") or "")
' 2>/dev/null)"
  if [[ -n "$title_pattern" ]]; then
    if ! T="$title" PAT="$title_pattern" python3 -c '
import os, re, sys
sys.exit(0 if re.search(os.environ["PAT"], os.environ["T"]) else 1)
' >/dev/null 2>&1; then
      printf '{"tier":4,"reason":"title-pattern-no-match title=%s","diff_lines":%s,"diff_files":%s}' \
        "$(printf '%s' "$title" | head -c 60 | tr -d '"\\')" "$diff_lines" "$changedFiles"
      return 0
    fi
  fi

  # 3c. size limits
  local max_lines max_files
  max_lines="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
print(((p.get("tier_1") or {}).get("match_all") or {}).get("max_lines_changed") or 0)
' 2>/dev/null)"
  max_files="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
print(((p.get("tier_1") or {}).get("match_all") or {}).get("max_files_changed") or 0)
' 2>/dev/null)"
  if (( diff_lines > max_lines )); then
    printf '{"tier":4,"reason":"diff-too-large lines=%s cap=%s","diff_lines":%s,"diff_files":%s}' \
      "$diff_lines" "$max_lines" "$diff_lines" "$changedFiles"
    return 0
  fi
  if (( changedFiles > max_files )); then
    printf '{"tier":4,"reason":"too-many-files files=%s cap=%s","diff_lines":%s,"diff_files":%s}' \
      "$changedFiles" "$max_files" "$diff_lines" "$changedFiles"
    return 0
  fi

  # 3d. paths_allowed (every touched path must match at least one) +
  #     paths_forbidden (no touched path may match any)
  local paths_allowed paths_forbidden
  mapfile -t paths_allowed < <(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
for x in ((p.get("tier_1") or {}).get("match_all") or {}).get("paths_allowed") or []:
    print(x)
' 2>/dev/null)
  mapfile -t paths_forbidden < <(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
for x in ((p.get("tier_1") or {}).get("match_all") or {}).get("paths_forbidden") or []:
    print(x)
' 2>/dev/null)

  while IFS= read -r touched_path; do
    [[ -z "$touched_path" ]] && continue

    if [[ ${#paths_forbidden[@]} -gt 0 ]] \
       && _path_matches_any "$touched_path" "${paths_forbidden[@]}"; then
      printf '{"tier":4,"reason":"path-forbidden-tier-1 path=%s","diff_lines":%s,"diff_files":%s}' \
        "$touched_path" "$diff_lines" "$changedFiles"
      return 0
    fi

    if [[ ${#paths_allowed[@]} -eq 0 ]] \
       || ! _path_matches_any "$touched_path" "${paths_allowed[@]}"; then
      printf '{"tier":4,"reason":"path-not-tier-1-allowed path=%s","diff_lines":%s,"diff_files":%s}' \
        "$touched_path" "$diff_lines" "$changedFiles"
      return 0
    fi
  done <<< "$files_list"

  # 3e. required_checks_success
  local required_checks
  mapfile -t required_checks < <(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
for x in ((p.get("tier_1") or {}).get("match_all") or {}).get("required_checks_success") or []:
    print(x)
' 2>/dev/null)
  local check_name
  for check_name in "${required_checks[@]}"; do
    [[ -z "$check_name" ]] && continue
    local conclusion
    conclusion="$(printf '%s' "$check_rollup" | \
      jq -r --arg n "$check_name" '[.[] | select(.name == $n) | .conclusion] | first // ""')"
    if [[ "$conclusion" != "SUCCESS" ]]; then
      printf '{"tier":4,"reason":"required-check-not-success check=%s state=%s","diff_lines":%s,"diff_files":%s}' \
        "$check_name" "${conclusion:-MISSING}" "$diff_lines" "$changedFiles"
      return 0
    fi
  done

  # 3f. mergeable_state allow-list
  local allowed_mergeable
  allowed_mergeable="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
ms = ((p.get("tier_1") or {}).get("match_all") or {}).get("mergeable_state") or []
print(",".join(ms))
' 2>/dev/null)"
  if ! printf ',%s,' "$allowed_mergeable" | grep -qF ",$mergeable,"; then
    printf '{"tier":4,"reason":"mergeable-state-not-allowed state=%s allowed=%s","diff_lines":%s,"diff_files":%s}' \
      "$mergeable" "$allowed_mergeable" "$diff_lines" "$changedFiles"
    return 0
  fi

  # All checks passed → Tier 1
  local touched_paths_csv
  touched_paths_csv="$(printf '%s' "$files_list" | tr '\n' ',' | sed 's/,$//')"
  printf '{"tier":1,"reason":"tier-1-eligible","diff_lines":%s,"diff_files":%s,"paths":"%s","title":"%s","author":"%s","mergeable":"%s","merge_state":"%s","base":"%s"}' \
    "$diff_lines" "$changedFiles" \
    "$(printf '%s' "$touched_paths_csv" | head -c 300 | sed 's/"/\\"/g')" \
    "$(printf '%s' "$title" | head -c 80 | sed 's/"/\\"/g')" \
    "$author" "$mergeable" "$merge_state" "$base"
  return 0
}

# When sourced, just expose the function. When executed directly,
# accept <repo> <pr> on the command line for ad-hoc testing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  classify_pr_tier "$1" "$2"
  echo
fi
