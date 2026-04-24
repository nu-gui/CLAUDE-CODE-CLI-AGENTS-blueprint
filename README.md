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

If Claude Code is already installed, open a session in the repo root (`~/.claude` after cloning) and paste the prompt below. Claude Code will read the key files, ask you for your environment values, and walk you through customizing each config — pausing at every step so you can adjust before anything lands.

````markdown
I've just cloned the CLAUDE-CODE-CLI-AGENTS-blueprint into this directory. It's
a generic multi-agent Claude Code framework that needs to be customized for my
environment before I use it. Please walk me through the full setup interactively.

First, read these files to understand what needs configuring:
- README.md (this overview)
- CLAUDE.md (agent framework + workflow rules)
- CUSTOMIZATION.md (detailed onboarding walkthrough)
- TEMPLATE_VARIABLES.md (placeholder reference)
- SECURITY.md (security posture + pre-commit checks)
- .env.example
- config/*.template (the five config files I need to populate)
- agents/*.md (scan filenames to see which specialists are available)
- .github/CODEOWNERS, .github/workflows/

Then work through this checklist, PAUSING for my input at each step:

1. **Identity** — Ask me for: GitHub org/user (GITHUB_ORG), my personal GitHub
   handle (GITHUB_USER), IANA timezone (e.g. America/New_York), and my primary
   machine's hostname. Create `.env` from `.env.example` with my values.

2. **Repos to automate** — Ask me to list the repos I want the pipeline to
   operate on (repo name → local clone path). Populate
   `config/nightly-repo-profiles.yaml` from its `.template` with one entry per
   repo. Ask per-repo what the deploy strategy is (skip / docker-compose /
   kubectl / custom) and apply sensible guards (`*.env*` deny,
   `migrations/**/*.sql` explicit-approve).

3. **Schedule** — Copy `config/nightly-schedule.yaml.template` to live form.
   Ask me which pipelines I actually want running (daytime-harrier /
   nightly-puffin / both / neither); I can disable any I don't need. Adjust
   cron times to my timezone.

4. **Other configs** — Copy `config/digest-config.yaml.template`,
   `config/doc-hygiene-profiles.yaml.template`,
   `config/product-profiles.yaml.template` to live forms. Ask me if I want
   each one enabled; leave disabled configs in their default (no-op) state.

5. **Agent roster** — List the agents in `agents/`. Ask me which specialists
   apply to my domain (e.g., I may not need `tel-core`/`tel-ops` if I'm not
   in telecom, or `ml-core` if I'm not doing ML). Delete unused agent files
   and trim the corresponding triggers from `CLAUDE.md`.

6. **Review rules** — Ask for my GitHub handle(s) and update
   `.github/CODEOWNERS`. Ask about my branching preference (GitHub flow
   main-only, feature→master→main, trunk-based, etc.) and update the
   relevant section in `CLAUDE.md`.

7. **Settings** — Copy `settings.json.template` to `settings.json`. Walk
   me through the hooks and permission allowlist; ask if I want to tighten
   anything before it's active.

8. **Bootstrap** — Run `bash scripts/bootstrap-fresh-machine.sh --dry-run`
   and show me the output. Ask for my explicit yes before running without
   `--dry-run`. After it completes, note any manual follow-ups it flagged
   (MCP reconnection, PAT setup, etc.).

9. **Verify** — Run `bash scripts/hive-doctor.sh`, `bash scripts/clone-doctor.sh`,
   and `bash scripts/hive-status.sh --observe`. Report any red flags.

10. **Summary** — Print a checklist of what's done, what I still need to do
    manually (GitHub PAT rotation, cron vs systemd decision, MCP reconnect at
    claude.ai/settings/connectors, inviting team members), and point me at
    `CUSTOMIZATION.md` §"Disable what you don't want" if I want to strip
    features later.

Safety rules (strict):
- Do NOT push to any GitHub repo without my explicit confirmation.
- Do NOT create issues, PRs, or external resources without asking.
- Do NOT run destructive operations (`rm -rf`, `git reset --hard`, etc.)
  without my yes.
- Prefer `--dry-run` when a script supports it; show output and ask before
  the real run.
- If a value I set conflicts with another config file, flag it and ask me
  to reconcile rather than guessing.
- Never commit `.env`, `settings.json`, `.credentials.json`, `*.pem`, or
  `*.key` — run `git status` before every commit and halt if any of those
  are staged.

Start at step 1.
````

Copy everything from ` ```markdown` to the closing ` ``` `, paste it into Claude Code as your first message, and step through the customization with Claude as your copilot. If at any step you prefer to skip Claude's guidance and do it yourself, say so — the framework doesn't care which path you take.

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
