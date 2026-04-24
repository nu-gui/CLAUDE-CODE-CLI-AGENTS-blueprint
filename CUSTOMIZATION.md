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

## Email delivery options (morning digest)

The `morning-digest.sh` script is always happy to write local markdown — by default it drops a file at `${HOME}/.claude/logs/morning-digest-YYYYMMDD.md` and nothing else happens. If you want email delivery too, pick ONE of the three paths and populate the matching env vars in `.env`:

### Option A — Gmail OAuth (creates a Gmail *draft* you review before sending)

Requires a one-time Google Cloud Console setup:

1. Visit [console.cloud.google.com](https://console.cloud.google.com/), create a project, enable the Gmail API.
2. Configure the **OAuth consent screen** (external / single-user is fine).
3. Create an **OAuth 2.0 Client ID** of type "Desktop app". Download the credentials JSON.
4. Place it at `${HOME}/.config/morning-digest-gmail/credentials.json`.
5. If your blueprint fork ships `scripts/setup-gmail-draft-oauth.sh`, run it — it creates a dedicated venv and walks you through the first-run OAuth token exchange.

In `.env`:

```
GMAIL_OAUTH_CREDENTIALS_PATH=${HOME}/.config/morning-digest-gmail/credentials.json
DIGEST_RECIPIENT_EMAIL=your-email@example.com
```

Known limitation: the OAuth consent screen is operator-gated and cannot be automated — you click through it once. Everything after that is automatic.

### Option B — SMTP (send directly via any provider)

Works with Gmail (with an [app password](https://myaccount.google.com/apppasswords)), Mailgun, AWS SES, Postmark, your company's SMTP, etc.

```
sudo apt install msmtp         # or ssmtp, whichever you prefer
```

In `.env`:

```
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=digest-bot@example.com
SMTP_PASS=your-app-password
DIGEST_RECIPIENT_EMAIL=your-email@example.com
```

`.env` is gitignored so the app password stays local. For extra safety, set `SMTP_PASS` via your OS keyring and reference it from the shell profile instead of the `.env` file.

### Option C — GitHub Discussion

Post the digest as a comment in a Discussion on one of your repos. Requires the target repo to have **Discussions** enabled (Settings → Features → Discussions).

```
DIGEST_TARGET_REPO=${GITHUB_ORG}/your-ops-repo
```

### Option D — None (default)

Leave all the above env vars unset. The digest lives only as local markdown under `${HOME}/.claude/logs/`.

---

## Environment discovery (before you customize)

If you're using the assisted Quickstart prompt from the README, Claude Code runs this automatically in Step 2. If you're doing it manually, check these before filling in configs — they influence some of the choices.

| Check | Why |
|---|---|
| Is `~/.claude` already populated? | You may be joining an existing setup; don't overwrite session memory |
| `gh auth status` | The automation scripts use `gh` extensively — ensure it's authenticated |
| `python3 --version` + `python3 -m venv --help` | Gmail OAuth path needs a venv (PEP 668 on Ubuntu 24.04+) |
| `systemctl --user list-timers` | If timers are already running, the bootstrap will conflict unless you stop them first |
| `crontab -l` | Same concern — cron entries from a previous setup may double-up |
| OS + `bash --version` | Scripts assume bash 5+; macOS default is 3.2 (install via brew) |
| Any existing `context/shared/patterns/ lessons/ decisions/` | These are your team's accumulated knowledge — preserve them |

---

## Respect existing `~/.claude` state

If you already have a working Claude Code setup and are ONLY adopting parts of this blueprint, merge carefully:

**Never overwrite:**
- `settings.json`, `.env`, `.credentials.json`
- `context/hive/sessions/` (active sessions)
- `context/hive/events.ndjson` (audit trail)
- `projects/`, `history.jsonl`
- `memory/MEMORY.md` (persistent agent memory)

**Merge (only add missing files):**
- `context/shared/patterns/`, `context/shared/lessons/`, `context/shared/decisions/` — your team's knowledge; on filename collision, KEEP YOURS

**Safe to replace (but back up first):**
- `agents/`, `handbook/`, `protocols/`, `hooks/`, `scripts/` — framework internals

Before replacing anything:

```bash
BACKUP_DIR=~/.claude-pre-blueprint-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
cp -r ~/.claude "$BACKUP_DIR/"
echo "backup: $BACKUP_DIR"
```

If you notice machine-specific tuning in the backup (custom hook paths, tool allowlists that matter to you, cron tuning) — port it into the new blueprint before you commit.

---

## Disable what you don't want

Blueprint ships with the full framework. If some of it is overkill for your team:

| Feature | How to disable |
|---|---|
| Nightly-puffin pipeline | Delete `scripts/nightly-*.sh`, `scripts/morning-*.sh`, `config/nightly-*.yaml` |
| Daytime-harrier | Delete `scripts/product-discovery.sh`, `scripts/doc-hygiene-scan.sh`, `scripts/evening-sprint-collate.sh` |
| PR sweeper | Delete `scripts/pr-sweeper.sh`, `docs/pr-sweeper*.md` |
| Delegate helper | Delete `scripts/delegate.sh` |
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
