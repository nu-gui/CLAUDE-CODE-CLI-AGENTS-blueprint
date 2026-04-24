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
