# CLAUDE-CODE-CLI-AGENTS-blueprint

A sanitized, forkable blueprint of a [Claude Code](https://claude.com/claude-code) multi-agent framework. Clone this, customize it for your environment, and use it as the backbone of your own Claude Code setup.

## What's in here

- **18 specialist agents** (`agents/`) — backend, frontend, data, ML, infra, QA, product, UX, telecom, comms, context, docs
- **Hive protocol** (`handbook/`, `protocols/`, `schemas/`) — recoverable session state, event bus, handoffs, dispatch snapshots
- **Hooks** (`hooks/`) — dispatch reminders, subagent-stop handlers, prompt-submit gates
- **Pipeline scaffolding** (`scripts/`) — nightly/daytime automation, PR sweeper, product discovery, hive doctor, bootstrap
- **Config templates** (`config/*.template`) — per-repo profiles, cron schedules, digests, doc hygiene, product discovery filters
- **Example docs** (`docs/`) — pipeline architecture, hive status, PR sweeper, disaster recovery, systemd timers

## What's NOT in here

By design, this blueprint excludes anything tied to a specific user, organization, or infrastructure:
- No user's `~/.claude` session state or memory
- No production SSH server inventory
- No organization-specific repo lists
- No timezone, author, or machine-specific values
- No historical commit/issue/PR data

Every user-facing path is `${HOME}`-relative. Every org reference is a `${GITHUB_ORG}` placeholder. Every repo name in examples is `example-repo`. Staff customize by setting a few env vars and editing a handful of templates.

## Quickstart (5 minutes)

```bash
# 1. Clone this blueprint to the canonical Claude Code location
git clone git@github.com:YOUR_ORG/CLAUDE-CODE-CLI-AGENTS-blueprint.git ~/.claude
cd ~/.claude

# 2. Bootstrap environment variables
cp .env.example .env
$EDITOR .env   # set GITHUB_ORG, GITHUB_USER, TIMEZONE, plus any hook preferences

# 3. Copy config templates to live forms and customize
for f in config/*.template; do cp "$f" "${f%.template}"; done
$EDITOR config/nightly-repo-profiles.yaml    # add your repos
$EDITOR config/nightly-schedule.yaml         # adjust cron times to your timezone

# 4. Copy settings.json.template → settings.json and review hook paths
cp settings.json.template settings.json

# 5. Run bootstrap to install systemd timers, plugins, PATH, etc.
bash scripts/bootstrap-fresh-machine.sh --dry-run   # preview
bash scripts/bootstrap-fresh-machine.sh             # execute

# 6. Verify
bash scripts/hive-doctor.sh
bash scripts/clone-doctor.sh --help
```

Full walkthrough: see [`CUSTOMIZATION.md`](CUSTOMIZATION.md).

## Quickstart — assisted (Claude Code walks you through it)

If Claude Code is already installed, open a session in the repo root (`~/.claude` after cloning) and follow this two-step routine:

1. **Switch to plan mode first** — press `Ctrl+J` in Claude Code and pick **Plan** (or run the `/plan` skill). Plan mode is read-only, so Claude will interview you and produce a customization plan without touching anything until you approve.
2. **Paste the prompt below** as your first message. Claude Code will scan your machine, interview you, and write a customization plan for your review before any file is written.

The prompt is intentionally thorough — every step, branch, and safety rule is written inline so Claude Code gets the full scope on paste. This is the single source of truth for the assisted flow; the blueprint is designed around this prompt, not around a separate spec file.

````markdown
I've just cloned CLAUDE-CODE-CLI-AGENTS-blueprint into this directory
(should be ~/.claude). It's a generic multi-agent Claude Code framework that
needs to be customized for MY environment and MY work style before I use it.
Plan mode is active. Please do thorough environment discovery, interview me
with enough questions to close all gaps, and produce a concrete customization
plan that I approve via ExitPlanMode before any file is touched.

━━━ STEP 1 — READ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Read (in this order):
  README.md, CLAUDE.md, CUSTOMIZATION.md, TEMPLATE_VARIABLES.md, SECURITY.md,
  .env.example, docs/event-contract.md, docs/disaster-recovery.md,
  docs/existing-state-merge.md, config/*.template (all five),
  agents/*.md (list the filenames), .github/CODEOWNERS,
  .github/workflows/, scripts/lib/common.sh.

━━━ STEP 2 — ENVIRONMENT DISCOVERY (read-only) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Before asking me anything, scan the machine and report findings as a
structured summary. Adapt every later question to what you find.

  A. Existing ~/.claude state
     - Does ~/.claude already contain a live Claude Code setup (agents/,
       hooks/, settings.json, context/, history.jsonl)?
     - Are there active sessions in context/hive/sessions/?
     - Are there session-memory files I should preserve
       (context/shared/patterns/, lessons/, decisions/, projects/*/landing.yaml,
       memory/MEMORY.md)?
     - If YES to any: DO NOT overwrite. Plan must merge/preserve, not clobber.

  B. Dependency inventory (report version or "MISSING")
     - gh (with `gh auth status`), jq, yq, python3, python3-venv, bash (>= 5),
       git (>= 2.40), systemd --user (or note WSL1 / macOS where it's absent),
       Optional: docker, docker-compose-v2, shellcheck, msmtp or ssmtp.

  C. Project directory layout
     - Is ~/github/ present? What's under it?
     - List directory entries at ~/github/ (one level deep, just names) so I
       can see what repos live there.
     - Are any already-cloned repos candidates for the pipeline?

  D. Shell + editor
     - $SHELL, $EDITOR, OS + distro + kernel, arch (x86_64 / arm64).

  E. Existing cron / systemd timers that might conflict
     - `crontab -l` summary (count + times touched by user)
     - `systemctl --user list-timers` summary.

Report findings, then proceed to Step 3.

━━━ STEP 3 — INTERVIEW ME (ask as many AskUserQuestion calls as needed) ━━━

Use AskUserQuestion generously — one well-formed question beats five
assumptions. Ask all of the following; adapt wording to what you found.

  1. **Identity**
     - GITHUB_ORG (required)
     - GITHUB_USER / personal GitHub handle (required)
     - IANA TIMEZONE (required, e.g. America/New_York)
     - Primary machine hostname (optional, just for documentation)

  2. **Repo scoping** (branch on my answer):
     Pick ONE:
       (a) Scan a project directory path and include ALL repos found there
           (ask me the path; default ~/github/$GITHUB_ORG/).
       (b) Cherry-pick a list of repo names.
       (c) Scan the path but apply INCLUSION or EXCLUSION patterns
           (ask for globs).
       (d) Skip repo config for now; I'll populate nightly-repo-profiles
           manually later.

  3. **Per-repo deploy strategy** (only if repos were scoped)
     For each selected repo, ask: deploy kind = skip / docker-compose /
     kubectl / custom-command. Apply sensible guards automatically
     (`*.env*` deny, `migrations/**/*.sql` explicit-approve).

  4. **Morning-digest delivery channel** (branch on my answer):
     Pick ONE:
       (a) Gmail OAuth — walk me through setup-gmail-draft-oauth.sh if it
           exists in this blueprint, OR walk me through the manual Google
           Cloud Console OAuth flow (consent screen is operator-gated).
           Populate GMAIL_OAUTH_CREDENTIALS_PATH + DIGEST_RECIPIENT_EMAIL
           in .env.
       (b) SMTP — populate SMTP_HOST/PORT/USER/PASS + DIGEST_RECIPIENT_EMAIL
           in .env. Check whether msmtp or ssmtp is installed; if neither,
           note it as a manual follow-up.
       (c) Local markdown only — no secrets needed; digest writes to
           ~/.claude/logs/morning-digest-YYYYMMDD.md.
       (d) GitHub Discussion — populate DIGEST_TARGET_REPO; ask which repo
           has Discussions enabled.
       (e) Disable digest entirely.

  5. **Agent roster**
     List all ~18 agents in agents/ with a one-line purpose. Ask which to
     KEEP and which to DELETE. A non-telecom team probably drops tel-core/
     tel-ops; a non-ML team drops ml-core; etc. Trim CLAUDE.md triggers to
     match the kept set.

  6. **Branching strategy**
     Pick ONE:
       (a) GitHub-flow main-only (simplest)
       (b) feature → master → main (the blueprint's source convention)
       (c) Trunk-based / other (I'll describe)
     Update CLAUDE.md §Branch Workflow to match.

  7. **Automation depth**
     Pick ONE:
       (a) Full — daytime-harrier + nightly-puffin (17 cron/timer entries)
       (b) Nightly-only — run overnight stages; skip daytime sweeps
       (c) Daytime-only — product discovery + mini dispatch; no overnight
       (d) None — I just want the agents; no automated pipeline
     If (a)–(c), pick systemd --user timers (preferred) OR crontab.

  8. **Code review / branch protections**
     - GitHub handles to add to .github/CODEOWNERS
     - Review policy: require N reviewers / require CI green / other

━━━ STEP 4 — CUSTOMIZATION PLAN (written to plan file, then ExitPlanMode) ━━

Using my answers + the discovery findings, write a concrete plan listing
exactly which files will be created/modified/deleted, which env vars and
yaml keys will take which values, which agents will be pruned, and which
scripts (if any) will be disabled. End with ExitPlanMode so I approve
before execution.

━━━ STEP 5 — EXECUTE (post-approval) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

After I approve the plan via ExitPlanMode:

  1. Create .env from .env.example; fill in the agreed values; do NOT stage.
  2. Copy each config/*.template → live form; populate per the plan.
  3. Edit CLAUDE.md (triggers, branching section).
  4. Delete unused agents/*.md; trim triggers.
  5. Update .github/CODEOWNERS with my handles.
  6. Copy settings.json.template → settings.json; show hooks + permissions;
     ask if I want to tighten anything.
  7. Run bash scripts/bootstrap-fresh-machine.sh --dry-run; show output;
     wait for my explicit yes before running without --dry-run.
  8. If automation selected, run scripts/install-systemd-timers.sh
     (--dry-run first, then for real after my yes).
  9. Verify: bash scripts/hive-doctor.sh, bash scripts/clone-doctor.sh,
     bash scripts/hive-status.sh --observe. Report any red flags.

━━━ STEP 6 — INTEGRATE WITH EXISTING STATE (if applicable) ━━━━━━━━━━━━━━━

If Step 2.A found an existing Claude Code setup:

  - PRESERVE (never overwrite): settings.json, .env, context/hive/sessions/,
    context/hive/events.ndjson, projects/, history.jsonl, memory/MEMORY.md.
  - MERGE into (never overwrite, add files only):
    context/shared/patterns/, context/shared/lessons/,
    context/shared/decisions/. If a filename collides, keep the existing
    version and report the conflict to me.
  - UPDATE (replace with blueprint versions, but back up old first):
    agents/*, handbook/*, protocols/*, hooks/*, scripts/*.
    Back up to ~/.claude-pre-blueprint-$(date +%Y%m%d-%H%M%S)/ and tell me
    where it went.
  - INSPECT for machine-specific tuning in the existing setup that I'd lose:
    cron tuning, custom hook paths, non-default tool allowlists. Flag these
    in the plan BEFORE execution.

  (See docs/existing-state-merge.md for the full policy — this prompt
  mirrors it inline so you have the rules self-contained on paste.)

━━━ STEP 7 — FINAL SUMMARY ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Print a checklist:
  ✓ Completed automatically
  ⚠ Manual follow-ups: MCP reconnection at claude.ai/settings/connectors,
    GitHub PAT rotation reminder (90 days), Google Cloud Console OAuth
    consent screen (if Gmail chosen), inviting team members to the blueprint
    fork, cron vs systemd choice confirmation
  ℹ Where to read more: CUSTOMIZATION.md §"Disable what you don't want",
    docs/disaster-recovery.md, docs/event-contract.md,
    docs/existing-state-merge.md

━━━ SAFETY RULES (strict, apply throughout) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

- Do NOT push to any GitHub repo without my explicit confirmation.
- Do NOT create issues, PRs, or external resources without asking.
- Do NOT run destructive operations (rm -rf, git reset --hard,
  git clean -fd, systemctl disable) without my explicit yes.
- Prefer --dry-run when a script supports it; show output and ask before
  the real run.
- If a value I set conflicts with another config file, flag it and ask me
  to reconcile rather than guessing.
- Never commit .env, settings.json, .credentials.json, *.pem, or *.key —
  run `git status` before every commit and halt if any of those are staged.
- If you find an existing ~/.claude setup, NEVER clobber it silently.
  Always back up + report + ask before replacing anything.
- If a dependency is missing, note it as a manual follow-up rather than
  auto-installing (user's package manager, not ours).

Begin with Step 1 (READ), then Step 2 (DISCOVERY) and report before Step 3.
````

Copy everything from ` ```markdown` to the closing ` ``` `, paste it into Claude Code as your first message (with plan mode active), and step through the customization with Claude as your copilot. If at any step you prefer to skip Claude's guidance and do it yourself, say so — the framework doesn't care which path you take. The prompt adapts itself to what your machine actually has; every machine this lands on is different, and the discovery phase exists specifically so nothing gets assumed.

## Mental model

Claude Code reads config from `~/.claude/`. This repo IS that config, version-controlled. The `.gitignore` keeps runtime state (`sessions/`, `projects/`, `history.jsonl`, `settings.json`, credentials) out of git; only the agent framework and tooling ship in the repo.

You can maintain TWO clones of this blueprint — one at `~/.claude/` (live runtime) and one under `~/github/YOUR_ORG/` (clean PR/branch work) — and use `scripts/clone-doctor.sh` to keep them in sync. See [`docs/disaster-recovery.md`](docs/disaster-recovery.md) for the recovery playbook.

## What to customize first

| File / area | What to change | Why |
|---|---|---|
| `.env` | `GITHUB_ORG`, `GITHUB_USER`, `TIMEZONE` | Every script reads these |
| `config/nightly-repo-profiles.yaml` | Your repo list + deploy targets | Drives nightly automation |
| `config/nightly-schedule.yaml` | Cron times in your timezone | Pipeline cadence |
| `CLAUDE.md` | Your team's agent triggers, workflow rules | Top-of-session guidance |
| `agents/*.md` | Keep as-is initially; tune triggers as you use them | Specialist roster |
| `settings.json` | Hook paths (usually default is fine) | Claude Code behavior |
| `.github/CODEOWNERS` | Your GitHub handles | Review routing |

See [`TEMPLATE_VARIABLES.md`](TEMPLATE_VARIABLES.md) for the full list of placeholders.

## Branching

The blueprint ships with a clean `main` default. The upstream maintainer uses a `feature/* → master → main` flow; you can adopt that, use GitHub flow (`feature/* → main`), or anything else. Nothing in the framework requires a particular branching strategy.

## Source

This blueprint is regenerated from an internal Claude Code agent framework. The generator (`scripts/make-blueprint.sh` in the source repo) strips user-specific values and produces this sanitized tree. Regenerated blueprints arrive as fresh commits; the source history is intentionally not carried over.

## License

See [`LICENSE`](LICENSE). The framework structure (agents, hive protocol, dispatch patterns) is free to adopt and adapt.

## Issues and contributions

This blueprint is meant to be forked and owned. Fork it to your own namespace, customize freely, and treat your fork as the starting point for your team. Upstream maintenance happens on a separate schedule; there's no commitment to accept PRs back to the blueprint.
