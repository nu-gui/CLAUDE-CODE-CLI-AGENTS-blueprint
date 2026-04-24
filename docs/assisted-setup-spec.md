# Assisted-Setup Spec

Canonical specification for the Claude-Code-assisted onboarding flow. When a staff member clones the blueprint and runs the short prompt from the README, Claude Code follows this document exactly.

This spec is the **single source of truth** for the step definitions, interview branches, and safety invariants. The README's Quickstart prompt delegates to this file; any future automation (CI check, wrapper script, test harness) should reference this same spec to prevent drift.

Keep this doc authoritative — if you change the assisted flow, change it here first, and the README prompt picks it up automatically via "read and follow this file" indirection.

---

## Prerequisites

Before Claude begins, the user must have switched Claude Code to **plan mode** (`Ctrl+J` → Plan). Plan mode is read-only; Claude interviews the user and produces a plan that the user approves via `ExitPlanMode` before any file is written. If plan mode isn't active, Claude should halt and ask the user to enable it.

---

## Step 1 — READ

Claude reads the following in order to orient itself:

- `README.md` (this blueprint's overview)
- `CLAUDE.md` (agent framework + workflow rules)
- `CUSTOMIZATION.md` (detailed onboarding walkthrough)
- `TEMPLATE_VARIABLES.md` (placeholder reference)
- `SECURITY.md` (security posture + pre-commit checks)
- `.env.example`
- `docs/event-contract.md` (dispatcher lifecycle events)
- `docs/disaster-recovery.md`
- `docs/existing-state-merge.md` (merge policy for existing `~/.claude` state)
- `config/*.template` (all config templates)
- `agents/*.md` (scan filenames for specialist inventory)
- `.github/CODEOWNERS`, `.github/workflows/`
- `scripts/lib/common.sh`

---

## Step 2 — ENVIRONMENT DISCOVERY (read-only)

Before asking the user anything, Claude scans the machine and reports a structured summary. Every later question adapts to what's discovered.

**A. Existing `~/.claude` state**
- Is `~/.claude` already populated (agents/, hooks/, settings.json, context/, history.jsonl)?
- Are there active sessions in `context/hive/sessions/`?
- Are there session-memory files to preserve (`context/shared/patterns/`, `lessons/`, `decisions/`, `projects/*/landing.yaml`, `memory/MEMORY.md`)?
- If any of the above: DO NOT overwrite. Plan must merge/preserve per [`existing-state-merge.md`](existing-state-merge.md).

**B. Dependency inventory** — report version or `MISSING`
- Required: `gh` (with `gh auth status`), `jq`, `yq`, `python3`, `python3-venv`, `bash` ≥ 5, `git` ≥ 2.40
- Scheduler: `systemd --user` (or note WSL1 / macOS alternative path)
- Optional: `docker`, `docker-compose-v2`, `shellcheck`, `msmtp` or `ssmtp`

**C. Project directory layout**
- Is `~/github/` present? What's under it?
- One-level directory listing so the user can see candidate repos.

**D. Shell + editor + OS**
- `$SHELL`, `$EDITOR`, OS + distro + kernel, architecture (x86_64 / arm64).

**E. Existing cron / systemd timers that might conflict**
- `crontab -l` summary (count + any times the user-config touches).
- `systemctl --user list-timers` summary.

After reporting, proceed to Step 3 — do not ask questions yet.

---

## Step 3 — INTERVIEW (use `AskUserQuestion` generously)

One well-formed question beats five assumptions. Adapt each question to what Step 2 found.

### 3.1 Identity
- `GITHUB_ORG` (required)
- `GITHUB_USER` / personal GitHub handle (required)
- IANA `TIMEZONE` (required, e.g. `America/New_York`)
- Primary machine hostname (optional, documentation only)

### 3.2 Repo scoping — pick ONE
- **(a) Scan all** — walk `${project_dir}/<org>/` and include every repo found (ask the path; default `~/github/${GITHUB_ORG}/`)
- **(b) Cherry-pick** — user lists repo names
- **(c) Scan with patterns** — user supplies inclusion / exclusion globs
- **(d) Skip** — user populates `nightly-repo-profiles.yaml` manually later

### 3.3 Per-repo deploy strategy (only if repos were scoped)
For each selected repo: `skip` / `docker-compose` / `kubectl` / custom command. Apply sensible guards automatically:
- `*.env*` → `deny`
- `migrations/**/*.sql` → `explicit-approve`

### 3.4 Morning-digest delivery channel — pick ONE
- **(a) Gmail OAuth** — walk through `scripts/setup-gmail-draft-oauth.sh` if present in the blueprint; otherwise document the manual Google Cloud Console OAuth flow. Populate `GMAIL_OAUTH_CREDENTIALS_PATH` + `DIGEST_RECIPIENT_EMAIL` in `.env`.
- **(b) SMTP** — populate `SMTP_HOST/PORT/USER/PASS` + `DIGEST_RECIPIENT_EMAIL` in `.env`. Check for `msmtp` or `ssmtp`; if missing, note as manual follow-up.
- **(c) Local markdown only** — no config. Digest writes to `${HOME}/.claude/logs/morning-digest-YYYYMMDD.md`.
- **(d) GitHub Discussion** — populate `DIGEST_TARGET_REPO`. Verify the target repo has Discussions enabled.
- **(e) Disable digest entirely**.

### 3.5 Agent roster
List every agent in `agents/` with a one-line purpose. Ask which to KEEP and which to DELETE. Typical trimming:
- Non-telecom teams drop `tel-core` / `tel-ops`
- Non-ML teams drop `ml-core`
- Solo developers may keep only `api-core` / `ui-build` / `test-00-test-runner`

Update the trigger table in `CLAUDE.md` to match the kept set.

### 3.6 Branching strategy — pick ONE
- **(a)** GitHub-flow `main`-only
- **(b)** `feature` → `master` → `main` (the blueprint's source convention)
- **(c)** Trunk-based / other (ask for description)

Update `CLAUDE.md` §"Branch Workflow" accordingly.

### 3.7 Automation depth — pick ONE
- **(a) Full** — daytime-harrier + nightly-puffin (17 cron/timer entries)
- **(b) Nightly-only** — overnight stages only; skip daytime sweeps
- **(c) Daytime-only** — product discovery + mini dispatch; no overnight
- **(d) None** — agents only; no automated pipeline

If (a)–(c): pick `systemd --user` timers (preferred) or `crontab`.

### 3.8 Code review / branch protections
- GitHub handles to add to `.github/CODEOWNERS`
- Review policy (N reviewers, CI-green requirement, etc.)

---

## Step 4 — PLAN FILE + `ExitPlanMode`

Using the answers + discovery findings, Claude writes a concrete customization plan to the plan file listing exactly:

- Which files will be created / modified / deleted
- Which env vars and YAML keys will take which values
- Which agents will be pruned
- Which scripts (if any) will be disabled
- Every `--dry-run` / `--yes` / approval checkpoint the execute phase will hit

Then calls `ExitPlanMode` for user approval. **Nothing is written until the user approves the plan.**

---

## Step 5 — EXECUTE (post-approval)

1. Create `.env` from `.env.example`; populate with approved values. **Do not stage.**
2. Copy each `config/*.template` → live form; populate per the plan.
3. Edit `CLAUDE.md` (triggers, branching section).
4. Delete unused `agents/*.md`; trim their triggers.
5. Update `.github/CODEOWNERS` with the user's handles.
6. Copy `settings.json.template` → `settings.json`; show hooks + permissions; ask if the user wants to tighten anything.
7. Run `bash scripts/bootstrap-fresh-machine.sh --dry-run`; show output; wait for explicit `yes` before running without `--dry-run`.
8. If automation was selected, run `scripts/install-systemd-timers.sh` (`--dry-run` first, real only after `yes`).
9. Verify: `bash scripts/hive-doctor.sh`, `bash scripts/clone-doctor.sh`, `bash scripts/hive-status.sh --observe`. Report any red flags.

---

## Step 6 — INTEGRATE WITH EXISTING STATE

If Step 2.A discovered an existing `~/.claude` setup, follow the canonical policy in [`docs/existing-state-merge.md`](existing-state-merge.md): never-overwrite list, merge-only list, safe-to-replace list, and the mandatory backup command before any replacement.

---

## Step 7 — FINAL SUMMARY

Print a three-bucket checklist:

- ✅ **Completed automatically** — list of every file written/modified during Step 5.
- ⚠️ **Manual follow-ups** — MCP reconnection at `claude.ai/settings/connectors`, GitHub PAT rotation reminder (90 days), Google Cloud Console OAuth consent screen (if Gmail chosen), inviting team members to the blueprint fork, cron vs systemd choice confirmation.
- ℹ️ **Further reading** — `CUSTOMIZATION.md` §"Disable what you don't want", `docs/disaster-recovery.md`, `docs/event-contract.md`, `docs/existing-state-merge.md`.

---

## Safety invariants (apply throughout every step)

These are **non-negotiable**. Claude must halt and ask the user rather than violate any of them.

| # | Rule | Why |
|---|---|---|
| 1 | Never push to any GitHub repo without explicit confirmation | Public side-effect, not reversible without admin action |
| 2 | Never create issues, PRs, or external resources without asking | Same |
| 3 | Never run destructive ops (`rm -rf`, `git reset --hard`, `git clean -fd`, `systemctl disable`) without explicit `yes` | Data loss risk |
| 4 | Prefer `--dry-run` when a script supports it; show output and ask before the real run | Sanity gate |
| 5 | If a user-provided value conflicts with another config, flag and ask | Silent assumptions decay over time |
| 6 | Never commit `.env`, `settings.json`, `.credentials.json`, `*.pem`, `*.key` — run `git status` before every commit and halt if any of those are staged | Secrets leak prevention |
| 7 | If an existing `~/.claude` setup is found, **never** clobber silently. Always back up + report + ask before replacing anything | Data loss risk, loss of accumulated team knowledge |
| 8 | If a dependency is missing, note it as a manual follow-up rather than auto-installing | User owns their package manager |

---

## Extending this spec

When adding or changing a step:

1. Update this file first. The README prompt picks up the change via "read and follow this file" — no duplicate content to maintain.
2. If a new interview branch is added, also update `TEMPLATE_VARIABLES.md` if new env vars are introduced, and `.env.example` to surface them (commented-out by default).
3. If a new never-overwrite path is discovered, update [`existing-state-merge.md`](existing-state-merge.md), not here.
4. Keep invariants stable — changing #1–8 needs deliberate discussion; they're why forks of this blueprint are safe.
