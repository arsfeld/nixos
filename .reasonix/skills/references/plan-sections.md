# Plan Sections — Implementation Plan Structure

## Purpose

An implementation plan bridges requirements to execution. It tells an implementer WHAT to build, WHERE to build it, WHAT to test, and WHAT could go wrong — without writing the code for them.

## Plan Quality Bar

Every plan should contain:
- A clear problem frame and scope boundary
- Concrete requirements traceability
- Repo-relative file paths for all proposed work
- Explicit test file paths for feature-bearing implementation units
- Decisions with rationale, not just tasks
- Existing patterns or code references to follow
- Enumerated test scenarios for each feature-bearing unit
- Clear dependencies and sequencing

A plan is ready when an implementer can start confidently without needing the plan to write the code for them.

## Required Sections

### Frontmatter

```yaml
---
title: "[one-line summary]"
date: YYYY-MM-DD
status: active
origin: "[path to requirements doc, if any]"
depth: [lightweight | standard | deep]
---
```

### Problem & Scope
- Problem frame (from requirements doc or user request)
- What's in scope and what's explicitly out
- Success criteria

### Requirements Trace
- R1, R2, ... mapped to Implementation Units
- Each requirement must be covered by at least one unit

### Key Technical Decisions
Decisions that materially affect implementation. Each with:
- What was decided
- Why (rationale)
- Alternatives considered and rejected

### Architecture / Design (Deep plans only)
- Component diagram or description
- Data flow
- Key interfaces/contracts

### Implementation Units
Each unit:
- **U1: [name]** — what this unit delivers
- **Files**: repo-relative paths to create/modify
- **Test files**: where tests go
- **Patterns to follow**: existing code to use as reference
- **Test scenarios**: enumerated, specific enough to implement directly
- **Dependencies**: other units this depends on
- **Risks**: what could go wrong

### Sequencing
Order of implementation units with rationale:
1. U3: [name] — because [reason]
2. U1: [name] — depends on U3
3. U2: [name] — independent, can run in parallel

### Risks & Mitigations
- Risk: [description]
- Likelihood: low | medium | high
- Impact: low | medium | high
- Mitigation: [what to do about it]

### Testing Strategy
- Unit test coverage expectations
- Integration test scenarios
- Manual testing steps (if applicable)
- Edge cases to verify

### Assumptions
Things assumed true that, if wrong, would change the plan.

## Include When Material

### Migration Strategy
If the change involves data migration, schema changes, or breaking API changes.

### Rollback Plan
If the change is risky or hard to undo.

### Deployment Notes
If the change requires specific deployment sequencing, feature flags, or environment config.

## Anti-Patterns

- **Pre-written code**: The plan should not include implementation code. Pseudo-code sketches are fine when they communicate design intent.
- **Vague test scenarios**: "Test the feature" is not a test scenario. "Given a user with 3 active subscriptions, when they cancel one, then only 2 remain active" is.
- **Missing file paths**: Every implementation unit should name the files it touches.
- **Task lists disguised as units**: "Add the button, then wire it up, then style it" are tasks within one unit, not separate units.
