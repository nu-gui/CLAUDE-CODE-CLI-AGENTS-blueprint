# context/

This directory holds your team's accumulated context: shared patterns, cross-project lessons, design decisions, and per-project state.

The blueprint ships it **empty** on purpose — context is your team's own knowledge, built up over time. Generic starting structure is below; populate as you go.

## Expected structure

```
context/
├── shared/                      # Cross-project knowledge
│   ├── patterns/                # PATTERN-XXX files (reusable approaches)
│   ├── lessons/                 # LESSON-XXX files (things learned the hard way)
│   └── decisions/               # DEC-XXX files (architectural decisions)
├── projects/                    # Per-project state (gitignored by default)
│   └── {project-name}/
│       └── landing.yaml         # Project summary, written by CTX-00
├── hive/                        # Runtime (mostly gitignored)
│   ├── sessions/                # Active + historical orchestrator sessions
│   ├── events.ndjson            # Append-only event stream
│   └── audits/                  # Audit reports
└── index.yaml                   # Master index
```

## Gitignored by default

Everything in `hive/sessions/`, `hive/active/`, `hive/completed/`, `hive/events.ndjson`, `projects/`, `hive/archive/`, `escalations/`, and `handoffs/` is `.gitignore`'d. Only the `shared/` subtree is tracked.

Add runtime dirs as needed — they'll be created on first agent spawn.

## How to build up `shared/`

Every time you hit a non-obvious problem and solve it, capture the lesson:

```bash
cat > context/shared/lessons/LESSON-001_pg-connection-pooling.md <<'EOF'
# LESSON-001: Postgres connection pooling under load

## Context
Service X exhausted Postgres connections under peak load.

## What we tried
...

## What worked
...
EOF
```

Similarly for patterns (`PATTERN-XXX_*`) and decisions (`DEC-XXX_*`). The agents will read these when they see related work, building on your institutional memory.

## First-run

On first use, Claude Code will create `hive/` subdirectories as needed. If you want to pre-create the structure:

```bash
mkdir -p context/{shared/{patterns,lessons,decisions},projects,hive/{sessions,active,completed,audits,archive}}
```

Then run `bash scripts/hive-doctor.sh` — it should report everything healthy.
