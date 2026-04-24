# Cross-Project Affinity Protocol v1.0

**Status**: Active
**Effective Date**: 2025-12-27
**Version**: 1.0
**Owner**: CTX-00 (Context Manager)
**Mode**: Ultra-Strict (Autonomous-Safe)

---

## Purpose

Keep shared hive knowledge powerful without contaminating projects. Prevent agents from pulling irrelevant patterns across repos.

---

## 1. Affinity Tagging

### Schema Addition for Shared Items

All PATTERN-XXX, LESSON-XXX, and DEC-XXX files may include:

```yaml
# In frontmatter
applies_to:
  - ai-agents-org
  - example-repo
  # Empty array = universal (applies to all)
```

### Tag Semantics

| `applies_to` Value | Meaning |
|--------------------|---------|
| `[]` (empty) | Universal. Applies to all projects. |
| `[project-a]` | Scoped. Only applies to project-a. |
| `[project-a, project-b]` | Multi-scoped. Applies to listed projects. |
| Not present | Treated as universal (backwards compatible). |

---

## 2. Relevance Ranking Rules

### ORC-00 / CTX-00 Behavior

When retrieving shared items for PROJECT_KEY:

| Condition | Relevance Rank |
|-----------|----------------|
| `applies_to` includes PROJECT_KEY | HIGH (include in context) |
| `applies_to` is empty/missing | MEDIUM (include if space permits) |
| `applies_to` excludes PROJECT_KEY | LOW (exclude unless explicit) |

### Down-Ranking Formula

```
if PROJECT_KEY not in applies_to and applies_to is not empty:
    relevance = base_relevance * 0.1  # 90% down-rank
```

### Explicit Override

Agents may explicitly reference a down-ranked item by ID:

```yaml
# In task or handoff
explicit_references:
  - PATTERN-005  # Include even if down-ranked
```

When explicitly referenced, down-ranking is bypassed.

---

## 3. Tagging Requirements

### When Creating Shared Items

| Item Type | Tagging Rule |
|-----------|--------------|
| PATTERN-XXX | Tag if derived from specific project context |
| LESSON-XXX | Tag if issue is project-specific |
| DEC-XXX | Tag if decision applies to subset of projects |

### Universal Items

Items that should remain universal:

- Language/framework best practices
- Security patterns
- Documentation standards
- General error handling

### Project-Specific Items

Items that should be tagged:

- Project-specific architecture decisions
- Patterns derived from unique project constraints
- Lessons from project-specific incidents

---

## 4. CTX-00 Responsibilities

### On Item Creation

1. Prompt creator for `applies_to` field
2. Default to empty (universal) if not specified
3. Validate PROJECT_KEYs exist in index.yaml

### On Context Retrieval

1. Filter by PROJECT_KEY affinity
2. Apply down-ranking to non-matching items
3. Include explicitly referenced items regardless

### On Project Deletion/Archive

1. Do NOT delete shared items
2. Remove project from `applies_to` arrays
3. Log removal in events.ndjson

---

## 5. Fail-Closed Conditions

| Condition | Action |
|-----------|--------|
| `applies_to` references non-existent project | WARN. Include item as universal. |
| Item explicitly referenced but down-ranked | Include item. Log override. |
| Shared item has no ID | REJECT. CTX-00 must assign ID. |
| Cross-project item pulled without affinity | Log as potential contamination. |

---

## 6. Anti-Patterns (Prohibited)

| Pattern | Why Prohibited |
|---------|----------------|
| Pulling all patterns regardless of project | Causes context bloat |
| Never tagging items | Reduces relevance filtering |
| Over-tagging as universal | Dilutes project focus |
| Removing tags after creation | Breaks audit trail |

---

## 7. Migration Path

For existing shared items without `applies_to`:

1. Treat as universal (backwards compatible)
2. CTX-00 may suggest tagging during review
3. No automated migration required

---

## 8. Audit Support

### Contamination Detection

Query for potential cross-project contamination:

```
SELECT items WHERE:
  applies_to does not include current PROJECT_KEY
  AND item was referenced in session
  AND not in explicit_references
```

### Affinity Report

CTX-00 can generate affinity report:

- Items per project
- Universal items count
- Down-ranked items pulled

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12-27 | Initial protocol |
