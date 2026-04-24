# Issue-First Workflow Protocol v1.0

> **Version**: 1.0 | **Last Updated**: 2026-01-11
> **Status**: Active | **Owner**: ORC-00
> **Mode**: Opt-in (not default)

---

## Overview

The Issue-First Workflow is an **opt-in enhancement** that creates GitHub issues for all work items before implementation begins. This provides:

- **Traceability**: Every code change links to an issue
- **Sprint Tracking**: Work organized into milestones
- **Audit Trail**: Issue comments track progress
- **Clean Git History**: One branch per issue, atomic PRs

---

## When to Use This Mode

| Scenario | Recommended Mode | Reason |
|----------|------------------|--------|
| Sprint/team work | **Issue-First** | Full traceability needed |
| Feature implementation | **Issue-First** | Multi-step work benefits from issue tracking |
| Quick fixes (<30 min) | **Direct** | Overhead not justified |
| Single-file changes | **Direct** | Too granular for issues |
| Exploration/research | **Minimal** | No commits expected |
| User says "quick fix" | **Direct** | Explicit bypass |

---

## Activation

### Explicit Activation (in prompt)

```
WORKFLOW_MODE: issue-first
```

### Auto-Detection Patterns

The bootstrap detects issue-first mode when prompt contains:

```
Pattern: /sprint|milestone|issue.?first|create\s+issues?|github\s+issues?/i
Pattern: /SPRINT_\d+|Sprint-\d{4}-W\d{2}/i
Pattern: User references sprint docs or backlog
```

### Project-Level Default (in landing.yaml)

```yaml
# ~/.claude/context/projects/{PROJECT_KEY}/landing.yaml
workflow:
  default_mode: issue-first  # or "direct" or "minimal"
  primary_branch: master     # or "main" or "auto"
  pr_target: master
  protected_branches: [main]
```

---

## Pre-Flight Gates

### Gate 0: GitHub Access Verification

**FAIL-CLOSED**: If GitHub access fails, offer alternatives.

```bash
# Verify authentication
gh auth status
if [ $? -ne 0 ]; then
  echo "GITHUB_ACCESS: FAIL - Not authenticated"
  echo "OPTIONS: 1) Run 'gh auth login' 2) Use direct mode 3) Manual issue creation"
  exit 1
fi

# Verify repo access
gh repo view --json name,defaultBranchRef 2>/dev/null
if [ $? -ne 0 ]; then
  echo "GITHUB_ACCESS: FAIL - Cannot access repo"
  exit 1
fi

# Verify write permissions (try to list issues)
gh issue list --limit 1 2>/dev/null
if [ $? -ne 0 ]; then
  echo "GITHUB_ACCESS: WARN - May not have write access"
fi

echo "GITHUB_ACCESS: PASS"
```

### Gate 1: Branch Verification

```bash
# Fetch all branches
git fetch --all --prune

# Detect primary branch (configurable)
PRIMARY_BRANCH="${PRIMARY_BRANCH:-$(git remote show origin | grep 'HEAD branch' | cut -d: -f2 | tr -d ' ')}"

# Fallback detection
if [ -z "$PRIMARY_BRANCH" ]; then
  if git show-ref --verify --quiet refs/remotes/origin/master; then
    PRIMARY_BRANCH="master"
  elif git show-ref --verify --quiet refs/remotes/origin/main; then
    PRIMARY_BRANCH="main"
  else
    echo "BRANCH_GATE: FAIL - Cannot detect primary branch"
    exit 1
  fi
fi

# Checkout and update
git checkout $PRIMARY_BRANCH
git pull origin $PRIMARY_BRANCH

# Verify clean state
if [ -n "$(git status --porcelain)" ]; then
  echo "BRANCH_GATE: FAIL - Working directory not clean"
  git status --short
  exit 1
fi

echo "BRANCH_GATE: PASS - On $PRIMARY_BRANCH, clean state"
```

---

## Issue Creation Standards

### Issue Title Format

```
[{AGENT}] {Short description}

Examples:
[API-CORE] Add rate limiting to /users endpoint
[UI-BUILD] Create login form component
[DATA-CORE] Add index to orders table
```

### Issue Body Template

```markdown
## Context
**Session**: {SESSION_ID}
**Sprint**: {MILESTONE_NAME}
**Agent**: {ASSIGNED_AGENT}

## Description
{Detailed description of what needs to be done}

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Tests pass
- [ ] Documentation updated (if applicable)

## Technical Notes
{Any technical context, related patterns, or constraints}

## Checkpoints
<!-- Agent updates this section during execution -->
- [ ] Started
- [ ] Implementation complete
- [ ] Tests written
- [ ] PR created

---
*Created by AI Agent Org Suite v3.8*
```

### Issue Labels

| Label | Usage |
|-------|-------|
| `agent:{agent-id}` | Assigned execution agent |
| `priority:high/medium/low` | Priority level |
| `area:{domain}` | Technical area (api, ui, data, infra) |
| `session:{SESSION_ID}` | Link to Hive session |
| `status:in-progress` | Work started |
| `status:blocked` | Work blocked |

---

## Branch Naming Convention

### Format

```
{issue_number}/{short-slug}

Examples:
118/fix-auth-bug
119/add-rate-limiting
120/update-user-schema
```

### Rules

1. **Issue number first** - Easy to find related issue
2. **Short slug** - Max 30 characters, lowercase, hyphens only
3. **No session ID in branch** - Kept in issue/PR for traceability
4. **Always branch from primary** - Never from feature branches

### Branch Creation

```bash
# Ensure on primary branch
git checkout $PRIMARY_BRANCH
git pull origin $PRIMARY_BRANCH

# Create issue branch
ISSUE_NUM=118
SLUG="fix-auth-bug"
git checkout -b "${ISSUE_NUM}/${SLUG}"
```

---

## Milestone Management

### Milestone Naming

```
Sprint-{YYYY}-W{WW}

Examples:
Sprint-2026-W02
Sprint-2026-W03
```

### Milestone Creation

```bash
# Check if milestone exists
MILESTONE_NAME="Sprint-2026-W02"
gh api repos/:owner/:repo/milestones --jq ".[] | select(.title==\"$MILESTONE_NAME\") | .number"

# Create if not exists
if [ -z "$MILESTONE_NUMBER" ]; then
  # Calculate due date (end of week)
  DUE_DATE=$(date -d "next sunday" +%Y-%m-%dT23:59:59Z)
  gh api repos/:owner/:repo/milestones -f title="$MILESTONE_NAME" -f due_on="$DUE_DATE" -f state="open"
fi
```

---

## Execution Loop

### Per-Issue Workflow

```
FOR each issue in execution_order:
  1. BRANCH: Create issue branch from primary
  2. SPAWN: Spawn assigned agent with issue context
  3. WORK: Agent implements with checkpoints
  4. UPDATE: Comment on issue with progress
  5. TEST: Run tests (if applicable)
  6. PR: Create PR targeting primary branch
  7. CHECKPOINT: Update todo.yaml and RESUME_PACKET.md
  8. NEXT: Move to next issue
```

### Agent Spawn Template (Issue-First Mode)

```
Task(subagent_type="{agent}", prompt="
SESSION_ID: {SESSION_ID}
PROJECT_KEY: {PROJECT_KEY}
WORKFLOW_MODE: issue-first

ISSUE CONTEXT:
- Issue: #{issue_number}
- Title: {issue_title}
- Branch: {issue_number}/{slug}
- Milestone: {milestone_name}

TASK: {task_description}

HIVE OBLIGATIONS:
1. Emit SPAWN event to events.ndjson
2. Checkpoint after each file modification
3. Comment on GitHub issue with progress (gh issue comment)
4. Emit COMPLETE event with outputs
5. Update RESUME_PACKET.md

GIT OBLIGATIONS:
1. Ensure on correct branch: {issue_number}/{slug}
2. Commit with message: '[#{issue_number}] {description}'
3. Push to origin before PR
")
```

### Issue Progress Comments

Agents should comment on issues at key points:

```bash
# Started work
gh issue comment $ISSUE_NUM --body "🚀 **Work Started**
- Agent: {AGENT_ID}
- Session: {SESSION_ID}
- Branch: \`{issue_number}/{slug}\`"

# Checkpoint
gh issue comment $ISSUE_NUM --body "📍 **Checkpoint**
- Files modified: {file_list}
- Status: {status}
- Next: {next_action}"

# Completed
gh issue comment $ISSUE_NUM --body "✅ **Implementation Complete**
- PR: #{pr_number}
- Files: {file_count} modified
- Tests: {test_status}"
```

---

## PR Creation

### PR Title Format

```
[#{issue_number}] {Issue title}

Example:
[#118] Add rate limiting to /users endpoint
```

### PR Body Template

```markdown
## Summary
Closes #{issue_number}

## Changes
- {change 1}
- {change 2}

## Test Plan
- [ ] Unit tests pass
- [ ] Integration tests pass
- [ ] Manual verification

## Session Context
- **Session**: {SESSION_ID}
- **Agent**: {AGENT_ID}
- **Milestone**: {MILESTONE_NAME}

---
*Generated by AI Agent Org Suite v3.8*
```

### PR Creation Command

```bash
gh pr create \
  --title "[#${ISSUE_NUM}] ${ISSUE_TITLE}" \
  --body "$(cat <<EOF
## Summary
Closes #${ISSUE_NUM}

## Changes
${CHANGE_LIST}

## Session Context
- **Session**: ${SESSION_ID}
- **Agent**: ${AGENT_ID}

---
*Generated by AI Agent Org Suite v3.8*
EOF
)" \
  --base "${PRIMARY_BRANCH}" \
  --assignee "@me"
```

---

## Error Handling

### GitHub API Failures

| Error | Action |
|-------|--------|
| Auth failure | Prompt user to run `gh auth login` |
| Rate limited | Wait and retry with backoff |
| No write access | Fall back to direct mode with warning |
| Issue creation fails | Log error, continue with local-only tracking |
| PR creation fails | Save PR body locally, provide manual instructions |

### Git Failures

| Error | Action |
|-------|--------|
| Branch already exists | Checkout existing branch, verify it's from primary |
| Merge conflicts | Report to user, do not auto-resolve |
| Push rejected | Pull and rebase, then retry |
| Dirty working directory | Stash or report, do not proceed |

---

## Integration with Hive v3.8

### todo.yaml Enhancement

```yaml
version: 1
session_id: example-repo_2026-01-11_1430
project_key: example-repo
workflow_mode: issue-first
last_updated: 2026-01-11T14:35:00Z
last_updated_by: orc-00

todos:
  - id: TODO-001
    title: Add rate limiting
    status: doing
    agent: api-core
    github_issue: 118
    github_issue_url: https://github.com/org/repo/issues/118
    branch: 118/add-rate-limiting
    pr: null
    checkpoints: 2

  - id: TODO-002
    title: Update user schema
    status: todo
    agent: data-core
    github_issue: 119
    github_issue_url: https://github.com/org/repo/issues/119
    branch: null
    pr: null
    checkpoints: 0
```

### RESUME_PACKET.md Enhancement

```markdown
# RESUME_PACKET - {SESSION_ID}

## Workflow Mode
**Mode**: issue-first
**Milestone**: Sprint-2026-W02
**Primary Branch**: master

## GitHub Issues Created
| Issue | Title | Agent | Status | Branch | PR |
|-------|-------|-------|--------|--------|-----|
| #118 | Add rate limiting | api-core | in-progress | 118/add-rate-limiting | - |
| #119 | Update user schema | data-core | pending | - | - |

## Current Work
- **Active Issue**: #118
- **Agent**: api-core
- **Branch**: 118/add-rate-limiting
- **Last Checkpoint**: 2026-01-11T14:35:00Z

## Next Actions
1. Complete rate limiting implementation
2. Create PR for #118
3. Start #119 (data-core)
```

---

## Compliance Checks (SUP-00)

Before session close, SUP-00 verifies:

| Check | Pass Condition |
|-------|----------------|
| All issues have branches | Every TODO with `github_issue` has `branch` |
| All branches from primary | `git merge-base --is-ancestor $PRIMARY_BRANCH $BRANCH` |
| All PRs target primary | PR base is `$PRIMARY_BRANCH` |
| No direct commits to protected | `git log --oneline $PROTECTED..HEAD` is empty |
| Issue comments updated | Each issue has at least "Started" and "Complete" comments |
| Milestone assigned | All issues assigned to milestone |

---

## Quick Reference

### Activation
```
WORKFLOW_MODE: issue-first
```

### Branch from primary
```bash
git checkout master && git pull && git checkout -b 118/fix-bug
```

### Create issue
```bash
gh issue create --title "[API-CORE] Fix bug" --body "..." --milestone "Sprint-2026-W02"
```

### Create PR
```bash
gh pr create --title "[#118] Fix bug" --base master
```

### Comment on issue
```bash
gh issue comment 118 --body "Checkpoint: files modified"
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-01-11 | Initial release - opt-in issue-first workflow with branch-per-issue |

---

**Related Documents**:
- `~/.claude/CLAUDE.md` - Workflow mode detection
- `~/.claude/context/agents/SESSION_PROMPTS.md` - Issue-first session prompt
- `~/.claude/context/agents/ai_agents_org_suite.md` - Master specification
