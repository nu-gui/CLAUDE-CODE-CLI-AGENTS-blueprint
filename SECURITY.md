# Security Posture

This blueprint ships safe defaults. This file documents what to watch out for as you customize.

## Secrets management

- `.credentials.json`, `.env`, `*.pem`, `*.key` are gitignored by default. Never commit them.
- Claude Code's `settings.json` contains hook paths and permission lists — `.gitignore`'d so machine-specific settings don't leak across installs. The tracked `settings.json.template` is the shared starting point.
- `.env.example` documents the placeholders. Your real `.env` stays local.

Before every push, verify:

```bash
git status --porcelain | grep -E '\.credentials\.json|\.env$|\.pem$|\.key$|settings\.json$'
# Should return no matches.
```

## PAT (Personal Access Token) posture

The blueprint assumes you use GitHub SSH for git operations (`git@github.com:`) and a PAT only for `gh` CLI. Recommendations:

1. **Use fine-grained PATs** over classic PATs where possible.
2. **Scope narrowly**: for scripts that only read issues/PRs/workflows, give a read-scoped PAT; for scripts that write (sweeper, dispatcher), a separate write-scoped PAT.
3. **Rotate on a schedule**: 90 days is a reasonable default. Add a reminder to your calendar.
4. **Store in `gh`'s credential helper**, not in `.env` — the blueprint's scripts use `gh api` which reads from the `gh` keyring automatically.

If you need to store a PAT in `.env` (for GitHub API calls outside `gh`), mark it clearly:

```bash
# .env — this file is in .gitignore but double-check before pushing
GITHUB_TOKEN=ghp_...   # WRITE scope
```

## Path guards

The dispatcher (`scripts/nightly-dispatch.sh`) honors per-repo `guards:` blocks in `config/nightly-repo-profiles.yaml`:

```yaml
guards:
  - {path: "*.env*",                mode: deny}                     # never touch
  - {path: "migrations/**/*.sql",   mode: explicit-approve}         # human gate
  - {path: "docs/trust/**",         mode: api-gov-review-required}  # specialist gate
```

Modes:
- `deny` — automation refuses to modify; human must edit directly
- `explicit-approve` — SUP-00 must sign off before merge
- `api-gov-review-required` — API-GOV agent must review

Apply liberally for anything sensitive (secrets, migrations, IAM, deploy configs).

## Audit trail

The hive system writes an append-only event stream to `${HOME}/.claude/context/hive/events.ndjson`. Every agent spawn, tool call, file modification, and completion is logged. For compliance-sensitive environments, consider periodically backing this file up:

```bash
# Nightly rotation (add to cron)
d=$(date +%Y%m%d)
cp ${HOME}/.claude/context/hive/events.ndjson /backup/hive/events-$d.ndjson
```

## Hook permissions

`settings.json` includes a `permissions.allow` and `permissions.deny` list that controls which Bash commands Claude Code can run without asking. The template ships with read-only commands allowed and mutations requiring approval. Review `settings.json.template` carefully before copying.

Tighten further by removing entries you don't want auto-approved:

```jsonc
"permissions": {
  "allow": [
    "Bash(git status:*)",
    "Bash(git log:*)",
    // remove lines you don't want auto-allowed
  ]
}
```

## Pre-commit checklist

Before committing customizations:

- [ ] No `.env`, `.credentials.json`, `*.pem`, `*.key` in `git status`
- [ ] No production IPs or hostnames in docs or configs (unless intentional and private)
- [ ] No hardcoded PATs/tokens anywhere (search: `grep -rn 'ghp_\|gho_\|ghs_\|github_pat_' .`)
- [ ] `.gitignore` still excludes runtime state under `context/hive/sessions/`, `projects/`, `history.jsonl`
- [ ] `settings.json` not staged (only `settings.json.template`)
- [ ] If you added new hooks/scripts, they don't log sensitive data

## Reporting security issues in the blueprint itself

If you find a security issue in the blueprint framework (not in your customizations), open a GitHub issue on your fork and decide whether to backport upstream. There's no formal disclosure process — this is an open template.
