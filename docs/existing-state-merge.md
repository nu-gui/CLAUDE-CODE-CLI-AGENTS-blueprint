# Existing-State Merge Policy

Canonical policy for adopting this blueprint on top of an already-populated `~/.claude/` directory. Referenced by the assisted-setup spec (Step 6), the README Quickstart prompt, and `CUSTOMIZATION.md`. When you edit the policy, edit it here — everything else links.

## When this matters

You already have a working Claude Code setup at `~/.claude/` (or wherever your runtime lives), and you're adopting this blueprint to adopt a framework — but without losing:

- Accumulated team knowledge (`context/shared/patterns/`, `lessons/`, `decisions/`)
- Active orchestrator sessions (`context/hive/sessions/`)
- Personal/machine-specific config (`settings.json`, `.env`)
- Audit trail (`context/hive/events.ndjson`, `history.jsonl`)
- Memory (`memory/MEMORY.md`, `projects/*/landing.yaml`)

The merge policy below prevents the blueprint from clobbering any of that.

## Categories

### 🔒 Never overwrite

Files/directories that represent the user's state. If present, leave them alone — blueprint equivalents (if any) are ignored.

| Path | Why |
|---|---|
| `settings.json` | Machine-specific hook paths, permission allowlists tuned over time |
| `.env` | Secrets, user-chosen defaults |
| `.credentials.json` | Secrets |
| `context/hive/sessions/` | Active orchestrator sessions — overwriting breaks running workflows |
| `context/hive/events.ndjson` | Append-only audit trail |
| `context/hive/active/`, `completed/`, `archive/` | Historical session state |
| `projects/` | Per-project runtime state (CTX-00 landing.yaml + session artifacts) |
| `history.jsonl` | Claude Code session history |
| `memory/MEMORY.md` | Persistent agent memory (user, feedback, project, reference entries) |
| `memory/*.md` | Individual memory files referenced by MEMORY.md |
| `plans/`, `tasks/` | In-flight plan and task state |

### 🤝 Merge (add missing files only)

Team knowledge that accumulates. Blueprint can add NEW patterns/lessons/decisions it introduces, but on filename collision, **keep the existing version**. Report every collision so the user can reconcile manually.

| Path | Reason |
|---|---|
| `context/shared/patterns/` | Reusable architectural / workflow patterns |
| `context/shared/lessons/` | Learned-the-hard-way knowledge |
| `context/shared/decisions/` | ADR-style design decisions |

### 🔄 Safe to replace (but back up first)

Framework internals that the blueprint owns. Replace with the blueprint's version, **after** backing up the old tree.

| Path | Notes |
|---|---|
| `agents/` | Agent definitions — back up any hand-tuned triggers, then replace |
| `handbook/` | Operational handbook |
| `protocols/` | Orchestration protocols |
| `hooks/` | Event hooks |
| `scripts/` | Pipeline scripts + helpers |
| `schemas/` | JSON schemas (if present) |
| `docs/` | Architecture/pattern docs |

## Mandatory backup before replacement

Before touching any "safe to replace" path, snapshot the existing state:

```bash
BACKUP_DIR=~/.claude-pre-blueprint-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BACKUP_DIR"
cp -r ~/.claude "$BACKUP_DIR/"
echo "backup at: $BACKUP_DIR"
```

Tell the user the backup path before proceeding. On rollback, `rsync -a "$BACKUP_DIR/" ~/.claude/` restores everything.

## Porting machine-specific tuning

After the backup is in place, inspect it for customizations worth preserving:

- **Custom hook paths** in the old `settings.json` — port the hook *paths* but not the whole file (user's `settings.json` stays untouched per "never overwrite").
- **Non-default tool allowlists** in `settings.json` — preserve. Widening allowlists typically doesn't need a blueprint upgrade.
- **Cron tuning** — user's existing cron entries for pipelines. If the blueprint installs systemd timers in the same namespace, uninstall cron equivalents first to prevent double-firing.
- **Agent-level tweaks** — any hand-edits to `agents/*.md` that weren't captured as a PR upstream. Re-apply on top of the blueprint's updated agents.

If any port is ambiguous, ask the user — don't guess.

## Conflict reporting format

When a merge-only path has a collision, report in this shape:

```
context/shared/patterns/PATTERN-001_example.md:
  EXISTS in ~/.claude (keeping yours)
  BLUEPRINT version available at: /path/to/blueprint/source
  Action: review both manually if you want to merge the two versions
```

Never silently drop either side. The user decides.

## Rollback

If anything goes wrong mid-merge:

1. Stop immediately — do not continue executing the plan.
2. `rsync -a --delete "$BACKUP_DIR/.claude/" ~/.claude/`
3. Report what was rolled back and why.

## For manual (non-assisted) adoption

These same rules apply whether Claude Code is driving the setup or you're doing it by hand. If you're adopting manually, scan `~/.claude/` against the three tables above before touching anything, run the backup command, and follow the same never-overwrite / merge / safe-to-replace discipline.
