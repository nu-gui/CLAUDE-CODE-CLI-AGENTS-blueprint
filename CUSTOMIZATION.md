# Customization Guide

A 30-minute walkthrough for adapting this blueprint to your own environment.

## 0. Prerequisites

- Ubuntu / Debian / macOS (scripts assume bash + GNU coreutils; on macOS, `brew install coreutils gnu-sed`)
- `git`, `gh` (GitHub CLI, authenticated), `jq`, `yq`
- An SSH key registered with GitHub (at `~/.ssh/id_ed25519_github` or similar)
- [Claude Code](https://claude.com/claude-code) installed

## 1. Fork and clone

```bash
# If not already forked, fork this repo to your own namespace on GitHub, then:
git clone git@github.com:YOUR_ORG/CLAUDE-CODE-CLI-AGENTS-blueprint.git ~/.claude
cd ~/.claude
```

You may also maintain a second "clean workspace" clone under your project directory:

```bash
git clone git@github.com:YOUR_ORG/CLAUDE-CODE-CLI-AGENTS-blueprint.git \
  ~/github/YOUR_ORG/CLAUDE-CODE-CLI-AGENTS-blueprint
```

Use `~/.claude/` as the live runtime and the `~/github/…/` clone for clean PR work. `scripts/clone-doctor.sh` keeps them in sync — see `docs/disaster-recovery.md`.

## 2. Set environment variables

```bash
cp .env.example .env
$EDITOR .env
```

Minimum values to set:

| Variable | Example | Used by |
|---|---|---|
| `GITHUB_ORG` | `acme-engineering` | All scripts, config templates, docs |
| `GITHUB_USER` | `alice-acme` | PR creation, issue assignment |
| `TIMEZONE` | `America/New_York` | Cron schedules, digest timestamps |

Source it into your shell:

```bash
source .env
export GITHUB_ORG GITHUB_USER TIMEZONE
```

For persistent use, add these exports to `~/.bashrc` or `~/.zshrc`.

## 3. Copy config templates

Every file under `config/` ending in `.template` is a starting point. Copy each to its live form and customize:

```bash
for f in config/*.template; do
  cp "$f" "${f%.template}"
done
```

Then edit:

### `config/nightly-repo-profiles.yaml`

This drives per-repo automation (deploy targets, guards, coupled groups). The template ships with one example entry; add your repos:

```yaml
repos:
  my-api:
    local_path: ${HOME}/github/${GITHUB_ORG}/my-api
    deploy:
      kind: docker-compose      # or: skip, docker, kubectl, custom
      command: "docker compose up -d --build"
    guards:
      - {path: "*.env*", mode: deny}
      - {path: "migrations/**/*.sql", mode: explicit-approve}
```

### `config/nightly-schedule.yaml`

The cron-like schedule for the pipeline. Default is UTC; adjust to your timezone:

```yaml
timezone: America/New_York
triggers:
  - name: nightly-select-projects
    cron: "30 23 * * *"          # 23:30 local
    script: nightly-select-projects.sh
```

### `config/digest-config.yaml`, `doc-hygiene-profiles.yaml`, `product-profiles.yaml`

Edit if you want digest emails, scheduled doc sweeps, or automated product discovery. Otherwise leave as-is — unused configs are harmless.

### `config/governance-policy.yaml`

Defines what agents may auto-approve vs what is locked to human-only review. **Read this carefully before enabling tier-1 auto-approval** — its `always_human.paths` list is the bright line that keeps your auth code, secrets, schemas, and prod deploys safe from drift.

```bash
cp config/governance-policy.yaml.template config/governance-policy.yaml
```

Two sections to customize:

- **`always_human.paths`**: anything matching a pattern here is mechanically locked to tier 4 (your review only). Add patterns specific to your org — e.g. trading strategies, customer data exporters, anything regulated.
- **`per_repo_overrides`**: lift specific paths in specific repos to tier 4 even if they'd otherwise qualify for tier 1.

Tier 1 (the only enabled tier in this blueprint) auto-approves PRs labelled `nightly-automation` whose diff is ≤30 lines, ≤5 files, all paths in the tier-1 allow-list, and Sourcery + security checks green. Disable by setting `tier_1.enabled: false` in the policy file (no other changes needed — the auto-approver short-circuits).

The policy file itself is in `always_human.paths` — meaning any change to it requires your review. Agents cannot expand their own approval jurisdiction.

## 4. Copy `settings.json.template`

```bash
cp settings.json.template settings.json
```

The template pre-wires hooks (`UserPromptSubmit`, `Stop`, `SubagentStart`) and a permission allowlist. Review the paths in `hooks.*.command` — they use `${HOME}/.claude/hooks/…` which should work as-is if you cloned to `~/.claude`. If you cloned elsewhere, adjust.

`settings.json` itself is gitignored; `settings.json.template` is the shared starting point.

## 5. Customize `CLAUDE.md`

Edit `CLAUDE.md` to reflect:

- Your branching strategy (main-only, master/main dual, GitHub flow, etc.)
- Specialist triggers that match your team's domains (remove agents you don't need, e.g. `tel-*` for non-telecom teams)
- Any team-specific conventions (PR templates, commit message format, review routing)

The blueprint version is a starting point, not prescriptive.

## 6. Customize agents

Agent definitions live in `agents/*.md`. For each agent you plan to use:

- Open the file, read the frontmatter (tools, effort, permissionMode)
- Adjust triggers in the description to match how your team talks about work
- Tune `tools:` to restrict if you want tighter safety

Agents you won't use (e.g. `tel-core`, `tel-ops` for non-telecom teams) can be deleted safely.

## 7. CODEOWNERS

Edit `.github/CODEOWNERS` to route reviews to your team's GitHub handles:

```
*                 @your-team
/agents/          @your-agents-team
/scripts/         @your-infra-team
```

## 8. Run the bootstrap

```bash
bash scripts/bootstrap-fresh-machine.sh --dry-run
# Review what it will do — install Claude Code CLI, systemd timers, PATH, etc.

bash scripts/bootstrap-fresh-machine.sh
# Execute.
```

The bootstrap is idempotent; safe to re-run.

## 9. Verify

```bash
bash scripts/hive-doctor.sh
bash scripts/clone-doctor.sh
bash scripts/hive-status.sh --observe    # quick 24h activity summary
```

All three should complete cleanly (hive-doctor may flag runtime directories to create on first run — that's expected).

## 10. First test run

Open Claude Code and ask something that matches a specialist trigger, e.g.:

> "Add a GET /healthz endpoint to my-api"

You should see Claude route to `api-core`, which should produce a PR against your default branch.

If Claude doesn't route to the specialist correctly, check the triggers table in `CLAUDE.md` and adjust wording to match how your team phrases work.

## Disable what you don't want

Blueprint ships with the full framework. If some of it is overkill for your team:

| Feature | How to disable |
|---|---|
| Nightly-puffin pipeline | Delete `scripts/nightly-*.sh`, `scripts/morning-*.sh`, `config/nightly-*.yaml` |
| Daytime-harrier | Delete `scripts/product-discovery.sh`, `scripts/doc-hygiene-scan.sh`, `scripts/evening-sprint-collate.sh` |
| PR sweeper | Delete `scripts/pr-sweeper.sh`, `docs/pr-sweeper*.md` |
| Delegate helper | Delete `scripts/delegate.sh` |
| Closure-loop watcher | Delete `scripts/closure-watcher.sh`, `docs/closure-watcher.md` |
| Tier-1 governance auto-approval | Set `tier_1.enabled: false` in `config/governance-policy.yaml`, OR delete `scripts/governance-auto-approve.sh` + `scripts/lib/risk-classifier.sh` + `config/governance-policy.yaml.template` + `docs/governance.md` |
| Pipeline smoke / health-check | Delete `scripts/smoke-test-pipeline.sh` + `scripts/pipeline-health-check.sh` |
| Self-update (cron tree sync) | Delete `scripts/self-update.sh` (only useful if you run the cron pipeline) |
| Workspace doc-sweep | Delete `scripts/workspace-doc-sweep.sh` |
| Specific agents | Delete their `agents/*.md` file |
| Hooks | Edit `settings.json` to remove the corresponding hook entries |

None of these are load-bearing for the agent framework itself.

## When the upstream blueprint updates

If you want to pull in fixes/improvements from upstream:

1. Clone the upstream blueprint to a sibling directory
2. Diff your customized tree against it
3. Cherry-pick the changes you want (typically in `agents/`, `handbook/`, `protocols/`, `hooks/`)
4. Leave your customized `CLAUDE.md`, `config/*.yaml`, `.env`, and `.github/CODEOWNERS` alone

There is no automated merge-back path, and that's intentional — your fork diverges from day one.

## Where to get unstuck

- Hive/protocol questions → `handbook/` and `protocols/`
- Agent behavior questions → `agents/{name}.md`
- Pipeline questions → `docs/nightly-puffin.md` / `docs/daytime-harrier.md`
- Fresh-machine/disaster-recovery → `docs/disaster-recovery.md`
- Script usage → each script has `--help`
