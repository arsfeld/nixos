---
name: ce-work
description: "Execute work systematically from a plan document or bare prompt. Reads the plan, creates a task list, implements each unit following existing patterns, tests continuously, and ships the completed feature. Use after ce-plan to execute, or directly with a work description."
argument-hint: "[plan doc path or description of work. Blank to auto-use latest plan doc]"
---

# Work Execution

Execute work efficiently while maintaining quality and finishing features. Takes a plan document or bare prompt and executes systematically.

## Core Principles

1. **The plan is your guide.** Implementation units, files, patterns, and test scenarios are specified there. Follow them.
2. **Test as you go.** Run tests after each change, not at the end. Fix failures immediately.
3. **Follow existing patterns.** Read referenced files first. Match naming conventions. Reuse existing components.
4. **Ship complete features.** Mark all tasks done before moving on. A finished feature beats a perfect one that doesn't ship.
5. **Incremental commits.** Commit each logical unit as you complete it.

## Input Document

<input_document> #$ARGUMENTS </input_document>

**If empty:** auto-detect the latest plan. Use `glob` with `docs/plans/*.md` sorted by mtime, pick the most recent.

## Execution Workflow

### Phase 0: Input Triage

**Plan document** (input is a file path to an existing plan) → skip to Phase 1.

**Bare prompt** (input is a description, not a file path):

1. **Scan the work area.** Identify files likely to change. Find existing test files. Note local patterns.

2. **Assess complexity:**

| Complexity | Signals | Action |
|-----------|---------|--------|
| **Trivial** | 1-2 files, no behavioral change (typo, config, rename) | Implement directly — no task list |
| **Small / Medium** | Clear scope, under ~10 files | Build task list. Proceed to Phase 1 |
| **Large** | Cross-cutting, 10+ files, auth/payments/migrations | Suggest `/ce-brainstorm` or `/ce-plan` first. Honor user's choice. |

### Phase 1: Quick Start

#### 1. Read the Plan

- Read the plan document completely
- Note: Implementation Units, Files, Test Scenarios, Patterns to Follow, Verification criteria
- Note any `Execution note` on units (test-first, characterization-first)
- Note any `Deferred to Implementation` questions
- Note `Scope Boundaries` — explicit non-goals
- If anything is unclear, ask now. Do not skip this.

#### 2. Setup Environment

Check current branch and decide:

```bash
git branch --show-current
```

**If on a feature branch:** Continue working on it. If the branch name is meaningless (auto-generated), suggest renaming.

**If on the default branch (main/master):** Create a new feature branch:

```bash
git checkout -b feat/<descriptive-name>
```

Derive the name from the plan title or work description.

#### 3. Create Task List

Use `todo_write` to break the plan into actionable tasks:
- Derive tasks from the plan's Implementation Units
- When the plan defines U-IDs, preserve them as task prefixes (e.g., "U3: Add parser coverage")
- Include dependencies between tasks
- Prioritize: foundation first, then dependent units
- Include testing and quality check tasks
- Keep tasks specific and completable

#### 4. Execution Strategy

Decide how to execute:

| Strategy | When |
|----------|------|
| **Inline** | 1-2 small tasks, or tasks needing user interaction. **Default for bare-prompt work.** |
| **Sequential subagents** | 3+ tasks with dependencies. Each subagent gets a focused unit. Dispatch via `run_skill` with `run_as: subagent`. |

For sequential subagents, give each one:
- The plan file path (for overall context)
- The specific unit's Goal, Files, Approach, Patterns, Test scenarios, Verification
- Instruction to implement, test, and report back

### Phase 2: Execute

#### Task Execution Loop

For each task in priority order:

```
while tasks remain:
  1. Mark task as in_progress
  2. Read any referenced files from the plan
  3. If the unit's work is already present (files exist, Verification criteria met), verify and skip
  4. Find existing test files for implementation files being changed
  5. Look for similar patterns in the codebase — read 2-3 examples
  6. Implement following existing conventions
  7. Add/update/remove tests to match implementation changes
  8. Run relevant tests:
     - Run the specific test file first
     - Then run the broader test suite if applicable
     - Fix failures immediately
  9. Run System-Wide Test Check (see below)
  10. Mark task as completed
  11. Evaluate for incremental commit (see below)
```

**Execution notes:** When a unit carries `Execution note: test-first`, write the failing test before implementation. When `characterization-first`, capture existing behavior before changing it. Skip test-first for trivial renames, config, or styling.

#### System-Wide Test Check

Before marking a task done, pause and ask:

| Question | Action |
|----------|--------|
| **What fires when this runs?** Callbacks, middleware, hooks — trace two levels out. | Read the actual code for side effects. |
| **Do my tests exercise the real chain?** If every dependency is mocked, the test proves isolation, not integration. | Write at least one integration test through the real chain. |
| **Can failure leave orphaned state?** If state is persisted before a risky call. | Trace the failure path. Test cleanup or idempotency. |
| **What other interfaces expose this?** Alternative entry points. | Grep for the method/behavior in related classes. |

Skip for leaf-node changes with no callbacks, no state persistence, no parallel interfaces.

#### Incremental Commits

After completing each task, evaluate whether to commit:

| Commit when... | Don't commit when... |
|----------------|---------------------|
| Logical unit complete | Small part of a larger unit |
| Tests pass + meaningful progress | Tests failing |
| About to switch contexts | Purely scaffolding |

```bash
# Stage only files related to this unit
git add <files>

# Commit with conventional message
git commit -m "feat(scope): description of this unit"
```

#### Follow Existing Patterns

- Read referenced files from the plan first
- Match naming conventions exactly
- Reuse existing components where possible
- When in doubt, `search_content` for similar implementations

#### Simplify as You Go

After completing a cluster of related units (every 2-3), review recently changed files for:
- Duplicated patterns to consolidate
- Shared helpers to extract
- Dead code to remove

### Phase 3: Quality Check

When all tasks are complete, read `.reasonix/skills/ce-work/references/shipping-workflow.md` for the full shipping workflow. Key steps:

1. **Run full test suite and linting**
2. **Code review** — invoke `/ce-code-review` for sensitive or large changes; inline review for small changes
3. **Final validation** — all tasks done, tests pass, patterns followed, requirements satisfied

### Phase 4: Ship

1. **Update plan status** — if the plan has `status: active` in YAML frontmatter, change to `status: completed`
2. **Commit and push:**

```bash
git add <all related files>
git commit -m "feat(scope): summary of completed work"
git push origin <branch>
```

3. **Notify user** — summarize what was completed, link to branch/PR, note follow-up work, suggest next steps

## Common Pitfalls

- **Skipping clarifying questions** — Ask now, not after building the wrong thing
- **Ignoring plan references** — The plan links to patterns for a reason
- **Testing at the end** — Test continuously or suffer later
- **80% done syndrome** — Finish the feature, don't move on early
- **Re-scoping into human-time phases** — The plan's Implementation Units define execution scope. Agents execute at agent speed. If a plan is too large, suggest `/ce-plan` to reduce scope.
