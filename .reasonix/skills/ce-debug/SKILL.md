---
name: ce-debug
description: "Systematically reproduce failures, trace root cause, form testable hypotheses, and implement test-first fixes. Use when the user says 'debug this', 'why is this broken', 'fix this bug', or describes broken behavior."
argument-hint: "[bug description, error message, or 'fix the bug where X']"
---

# Systematic Debugging

`ce-debug` traces causal chains, forms testable hypotheses, and implements test-first fixes. It does not guess — it reproduces, isolates, and verifies.

## Core Principles

1. **Reproduce first.** Never fix what you can't reproduce. A fix without reproduction is a guess.
2. **One hypothesis at a time.** Form a specific, falsifiable hypothesis. Test it. If wrong, form the next one.
3. **Test before fix.** Write a test that fails with the bug, then make it pass. This proves you understood the bug AND that your fix works.
4. **Root cause, not symptom.** Fixing the symptom patches; fixing the root cause prevents recurrence.
5. **Document dead ends.** Failed hypotheses are valuable — they prevent others from repeating the same wrong path.

## Bug Description

<bug_description> #$ARGUMENTS </bug_description>

**If empty, ask:** "What's broken? Describe the bug, error message, or unexpected behavior."

## Execution Flow

### Phase 0: Triage

Before diving in, quickly assess:

1. **Is this actually a bug?** Distinguish bugs from missing features, configuration issues, or usage errors.
2. **Is there enough information?** Do we have: error messages, steps to reproduce, expected vs actual behavior, environment details?
3. **What's the blast radius?** Is this in production? Affecting users? Data at risk?

If information is sparse, ask one targeted question to fill the biggest gap.

### Phase 1: Reproduce

#### 1.1 Find Reproduction Steps

Based on the bug description, identify or discover:
- Exact steps to trigger the bug
- Any preconditions (specific data, state, config)
- Environment where it occurs (OS, version, dependencies)

If steps aren't provided, read the relevant code to form an initial hypothesis about trigger conditions, then verify.

#### 1.2 Reproduce Locally

If possible, reproduce the bug:
- Set up the preconditions
- Run the trigger steps
- Confirm you see the same error/behavior

If you can't reproduce, say so explicitly and explain what you tried. Work from code analysis if reproduction isn't feasible.

### Phase 2: Trace

#### 2.1 Map the Causal Chain

From the symptom, trace backward:
1. What's the immediate failure? (error message, wrong output)
2. What code path produced it? (trace from entry point to failure)
3. What state or input triggered that path? (what data/conditions)
4. Where did that state come from? (upstream source)

Read the relevant code files. Use `search_content` to trace callers and data flow.

#### 2.2 Form Hypotheses

For each candidate root cause, form a falsifiable hypothesis:
- "If X is the root cause, then Y should be true and Z should be observable."
- "If we fix X by doing W, the bug should disappear AND no other behavior should change."

Rank hypotheses by likelihood. Start with the simplest.

### Phase 3: Fix

#### 3.1 Write a Failing Test

Before touching the fix, write a test that:
- Demonstrates the bug (fails without the fix)
- Is minimal — only what's needed to trigger the bug
- Will catch regressions in the future

Run the test to confirm it fails.

#### 3.2 Implement the Fix

Make the smallest change that makes the test pass. Consider:
- Is this fixing the root cause or a symptom? If symptom, what's the root cause?
- What else depends on this code? Check callers with `search_content`.
- Could this fix break anything else? Think through side effects.

#### 3.3 Verify

- Run the reproduction test — it should pass
- Run existing tests: `just build <hostname>` or the project's test command
- If applicable, verify the fix in context (not just the unit test)

### Phase 4: Prevent

#### 4.1 Add Regression Tests

Beyond the reproduction test, add tests for:
- Adjacent edge cases that could have the same root cause
- Error paths that should now be handled
- Boundary conditions

#### 4.2 Consider Systemic Prevention

Ask: "How could this class of bug be prevented in the future?"
- Could a lint rule catch this?
- Could a type be tightened?
- Could a test helper make this easier to test?
- Should `docs/solutions/` capture this pattern?

If a systemic prevention is low-effort, implement it. Otherwise note it for later.

### Phase 5: Document and Close

Summarize:
- Root cause (1 sentence)
- Fix applied (1 sentence)
- Tests added
- Prevention (if any)

Suggest running `/ce-compound` if the bug was non-trivial — it will document the solution in `docs/solutions/` for future reference.

## Anti-Patterns

- **Fixing without reproducing**: You don't know if the fix works.
- **Fixing without a test**: You can't prove the fix works, and it will regress.
- **Changing multiple things at once**: You won't know which change fixed it.
- **Silent fixes**: If you fix a bug you found during other work, flag it explicitly.
- **Guessing**: Each hypothesis should be grounded in evidence from the code or reproduction.
