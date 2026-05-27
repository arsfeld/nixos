---
name: ce-code-review
description: "Structured code review using specialized reviewer subagents. Spawns parallel reviewers for correctness, security, and testing, then merges findings into a single report. Use before creating a PR or after completing a task."
argument-hint: "[blank to review current branch, or provide PR number / branch name]"
---

# Code Review

Reviews code changes using specialized reviewer subagents. Spawns parallel subagents that return structured findings, then merges and deduplicates into a single report.

## When to Use

- Before creating a PR
- After completing a task
- When feedback is needed on any code changes

## Severity Scale

| Level | Meaning | Action |
|-------|---------|--------|
| **P0** | Critical breakage, exploitable, data loss | Must fix before merge |
| **P1** | High-impact defect, breaking contract | Should fix |
| **P2** | Moderate issue (edge case, perf, maintainability) | Fix if straightforward |
| **P3** | Low-impact, minor improvement | Discretionary |

## Reviewer Selection

### Always-on reviewers (every review)

| Reviewer | Focus |
|----------|-------|
| `ce-correctness-reviewer` | Logic errors, edge cases, state bugs, error propagation |
| `ce-testing-reviewer` | Coverage gaps, weak assertions, brittle tests |

### Conditional reviewers (selected by diff content)

| Reviewer | Select when diff touches... |
|----------|---------------------------|
| `ce-security-reviewer` | Auth, public endpoints, user input, permissions, secrets |

## How to Run

### Stage 1: Determine Scope

**If a PR number or GitHub URL is provided:**
```
gh pr view <number-or-url> --json title,body,baseRefName,headRefName,url
gh pr diff <number-or-url>
```

**If a branch name is provided:**
```
git checkout <branch>
BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null)
git diff $BASE
```

**If no argument (standalone on current branch):**
```
BASE=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD origin/master 2>/dev/null)
git diff $BASE
```

If no base can be resolved, use `git diff HEAD~1` as fallback and note the limitation.

Capture:
- Changed file list
- Diff content
- Branch name / PR metadata

### Stage 2: Intent Discovery

Understand what the change is trying to accomplish:
- Read commit messages: `git log --oneline ${BASE}..HEAD`
- If PR: read the PR title and body
- Write a 1-2 line intent summary

### Stage 3: Dispatch Reviewers

For each selected reviewer, use `run_skill` with the diff content and intent summary as arguments. Run them sequentially (Reasonix subagent skills are synchronous).

Always dispatch:
1. `ce-correctness-reviewer` — pass: "Intent: {intent summary}\n\nDiff:\n{diff content}"
2. `ce-testing-reviewer` — pass: "Intent: {intent summary}\n\nDiff:\n{diff content}"

Conditionally dispatch:
3. `ce-security-reviewer` — if diff touches auth, endpoints, user input, permissions, or secrets

### Stage 4: Merge and Deduplicate

Combine findings from all reviewers:
1. Group by file:line
2. Merge overlapping findings (same issue spotted by multiple reviewers) — keep the more detailed version
3. Sort by severity: P0 first, then P1, P2, P3
4. Assign stable finding numbers (#1, #2, ...)

### Stage 5: Present Report

```
## Code Review — {branch or PR}

**Intent:** {1-2 line summary}
**Scope:** {N files changed}
**Reviewers:** correctness, testing[, security]

### Findings

**#1 [P0] [file:line] — [title]**
- Issue: [what's wrong]
- Suggested fix: [how to fix]
- Reviewer: [which reviewer found it]
- Confidence: [high | medium | low]

**#2 [P1] [file:line] — [title]**
...

### Summary
- P0: N (must fix), P1: N (should fix), P2: N, P3: N
- Verdict: [ready to merge | fix P0s first | recommend review]

### Next Steps
```

### Stage 6: Handoff

Present next-step options using `ask_choice`:

1. **Fix P0 issues** — I'll apply the suggested fixes
2. **Review findings** — let me walk through each one
3. **Proceed as-is** — I understand the risks
4. **Compound the learning** — run /ce-compound for any notable fixes
