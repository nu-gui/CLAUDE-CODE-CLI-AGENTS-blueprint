# Template Variables

Every placeholder you'll encounter in this blueprint, what it means, and where it appears.

## Core placeholders

### `${HOME}`

Your home directory. Shell expands this automatically in most contexts; scripts use it directly.

Appears in: every script, most docs, config paths.

No action required — bash handles it.

### `${USER}`

Your local username. Used in machine-specific contexts (PostgreSQL user, log paths).

Appears in: `scripts/bootstrap-fresh-machine.sh`, `scripts/install-systemd-timers.sh`, some doc examples.

No action required — bash handles it.

### `${GITHUB_ORG}`

Your GitHub organization or user namespace. This is the primary thing you'll set.

Appears in: `.env`, `config/*.template`, `CLAUDE.md`, `README.md`, `scripts/bootstrap-fresh-machine.sh`, scripts that operate on repos.

Set via:

```bash
# .env
GITHUB_ORG=acme-engineering

# or exported globally
export GITHUB_ORG=acme-engineering
```

### `${GITHUB_USER}`

Your personal GitHub handle (used for PR creation, issue assignment, CODEOWNERS).

Appears in: `.env`, `.github/CODEOWNERS`, some docs.

Set via: `.env` or global export.

### `${TIMEZONE}`

IANA timezone name (`America/New_York`, `Europe/Berlin`, etc.). Used by cron schedules and digest timestamp formatting.

Appears in: `config/nightly-schedule.yaml.template`, `config/digest-config.yaml.template`, some docs.

Set via: `.env` or global export. Default is `UTC`.

## Secondary placeholders

### `${SESSION_ID}`, `${PROJECT_KEY}`, `${AGENT_ID}`, `${TASK_SUMMARY}`

Set by the orchestrator in each agent's spawn environment. You don't set these; they're populated at runtime when the orchestrator dispatches an agent.

Appears in: `agents/_HIVE_PREAMBLE_v3.8.md` and every agent that uses it.

### `${EXPECTED_REMOTE}`

Git remote URL that `clone-doctor.sh` expects. Default value in the script points to the upstream source; override in your fork:

```bash
EXPECTED_REMOTE="git@github.com:${GITHUB_ORG}/CLAUDE-CODE-CLI-AGENTS-blueprint.git" \
  bash scripts/clone-doctor.sh
```

Or edit the default at the top of `scripts/clone-doctor.sh` directly for your fork.

## Placeholder strings in examples

Generic strings you'll see in docs and config templates:

| Placeholder | Replace with |
|---|---|
| `example-repo` | The name of a real repo in your `${GITHUB_ORG}` |
| `example-org` | Your `${GITHUB_ORG}` value |
| `your-workstation` | Your primary dev machine alias/hostname |
| `your-email@example.com` | Your email for digest delivery |
| `your-github-handle` | Your GitHub username |
| `@your-reviewer` | Your team's reviewer/code-owner |
| `REDACTED_IP` | Your production/staging IP if applicable |
| `YOUR_ORG`, `YOUR_GITHUB_ORG` | Your GitHub org (prose usage) |
| `Team Lead` / `Operator` | Your role names |

## Finding remaining placeholders in YOUR tree

After customizing, audit for anything you missed:

```bash
cd ~/.claude
grep -rn 'example-repo\|example-org\|your-workstation\|YOUR_ORG\|REDACTED_IP' \
  --include='*.md' --include='*.yaml' --include='*.sh' .
```

Run this periodically as you adopt the framework — as you enable more features (digest, sweeper, discovery), additional placeholders will surface.

## Files most likely to contain placeholders after customization

Ordered by sensitivity:

1. `config/nightly-repo-profiles.yaml` — if you haven't added your repos yet, still shows `example-repo`
2. `config/digest-config.yaml` — email target still `example.com`?
3. `.github/CODEOWNERS` — still says `@your-reviewer`?
4. `CLAUDE.md` — any branch rules still reference the upstream workflow?
5. `docs/*.md` — architecture docs reference `${GITHUB_ORG}` — usually fine, occasionally needs tuning
