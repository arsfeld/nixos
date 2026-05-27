# Shipping Workflow — Phase 3-4

This is loaded when all Phase 2 tasks are complete and execution transitions to quality check and shipping.

## Phase 3: Quality Check

### 1. Run Core Quality Checks

Always run before submitting:

```bash
# Run full test suite
# Use the project's test command

# Run linting / formatting
# Use the project's formatter
```

### 2. Code Review (REQUIRED)

Every change gets reviewed before shipping. Use `run_skill` to invoke `ce-code-review`.

If the change is small and concentrated (under ~400 lines, no auth/payments/migrations), a quick inline review is sufficient. For larger or sensitive changes, invoke the full `ce-code-review` skill.

### 3. Final Validation

- [ ] All tasks marked completed
- [ ] Tests pass
- [ ] Linting/formatter passes
- [ ] Code follows existing patterns
- [ ] If the plan has a `Requirements` section, verify each requirement is satisfied
- [ ] Any `Deferred to Implementation` questions were resolved

## Phase 4: Ship It

### 1. Update Plan Status

If the plan has a `status: active` in its YAML frontmatter, update it to `status: completed`.

### 2. Commit

Stage all related files:

```bash
git add <files>
```

Commit with a conventional commit message derived from the plan:

```bash
git commit -m "feat(scope): description of the completed work"
```

For multi-unit work, consider whether to squash into one commit or keep incremental commits. Prefer one commit per logical change.

### 3. Push

```bash
git push origin <branch>
```

### 4. Create PR (if applicable)

If this repo uses PRs, create one with a description that includes:
- Summary of what was built
- How it was tested
- Link to the plan document
- Any known limitations or follow-up work

### 5. Notify User

Summarize:
- What was completed
- Where the code lives (branch, PR if applicable)
- Any follow-up work needed
- Suggested next steps
