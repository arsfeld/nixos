---
name: ce-plan
description: "Create structured implementation plans for multi-step tasks — software features, refactors, or any goal that benefits from breakdown. Use when the user says 'plan this', 'create a plan', 'how should we build', or when a brainstorm doc is ready for planning."
argument-hint: "[optional: feature description, requirements doc path, or any task to plan]"
---

# Create Technical Plan

`ce-brainstorm` defines **WHAT** to build. `ce-plan` defines **HOW** to build it. `ce-work` executes the plan.

A prior brainstorm is useful context but never required — `ce-plan` works from any input: a requirements doc, a bug report, a feature idea, or a rough description.

**When directly invoked, always plan.** If the input is unclear, ask clarifying questions — but always stay in the planning workflow.

This workflow produces a durable implementation plan. It does **not** implement code or run tests.

**All file references in the plan must use repo-relative paths, never absolute paths.**

## Core Principles

1. **Use requirements as the source of truth** — If a requirements doc exists, build from it.
2. **Decisions, not code** — Capture approach, boundaries, files, dependencies, risks, and test scenarios. Do not pre-write implementation code.
3. **Research before structuring** — Explore the codebase and prior learnings before finalizing the plan.
4. **Right-size the artifact** — Small work gets a compact plan. Large work gets more structure.
5. **Separate planning from execution discovery** — Resolve planning-time questions here. Defer execution-time unknowns.
6. **Keep the plan portable** — It should work as a living document, review artifact, or issue body.

## Interaction Method

Use `ask_choice` for all user decisions. Ask one question at a time.

## Feature Description

<feature_description> #$ARGUMENTS </feature_description>

**If empty, ask:** "What would you like to plan? Describe the task, goal, or project you have in mind."

## Workflow

### Phase 0: Source and Scope

#### 0.1 Resume Existing Plan

If the user references an existing plan in `docs/plans/`:
- Read it
- Confirm whether to update in place or create new
- If updating, revise only the still-relevant sections

#### 0.2 Find Upstream Requirements Document

Search `docs/brainstorms/` for files matching `*-requirements.md`. A requirements doc is relevant if:
- The topic matches the feature description
- It was created within the last 30 days
- It covers the same user problem or scope

If found, read it thoroughly and carry forward: problem frame, requirements (R-IDs), actors (A-IDs), flows (F-IDs), acceptance examples (AE-IDs), scope boundaries, decisions, dependencies, and outstanding questions.

If no requirements doc exists, planning may proceed from the user's request directly.

#### 0.3 Planning Bootstrap (No Requirements Doc)

If no requirements doc exists and the input needs more structure:
- Establish: problem frame, intended behavior, scope boundaries, non-goals, success criteria
- If major product questions are unresolved, suggest `ce-brainstorm` but offer to continue here
- If the user wants to continue, require explicit assumptions

**Bug-shaped prompt** (user describes broken behavior): Suggest `ce-debug` as an alternative alongside continuing with `ce-plan`.

#### 0.4 Assess Plan Depth

- **Lightweight** — small, well-bounded, low ambiguity
- **Standard** — normal feature or bounded refactor
- **Deep** — cross-cutting, strategic, high-risk

#### 0.5 Scoping Synthesis (Solo Mode Only)

If there was no upstream requirements doc, surface a scoping synthesis before spending research effort:

**Lightweight with no call-outs:** "Planning: [1-3 line scope claim]. No open decisions — proceeding to research."

**Standard/Deep or any tier with call-outs:** Full scope claim with call-outs and confirmation gate.

### Phase 1: Gather Context

#### 1.1 Local Research

Prepare a concise planning context summary (1-2 paragraphs).

Run these subagents using `run_skill`:

1. `ce-repo-research-analyst` — pass: "Scope: technology, architecture, patterns. {planning context summary}"
2. `ce-learnings-researcher` — pass: the planning context summary

Collect: technology stack, architectural patterns, relevant files, institutional learnings from `docs/solutions/`, AGENTS.md/CLAUDE.md guidance.

Also read `STRATEGY.md` if it exists for product grounding.

#### 1.2 Decide on External Research

Consider whether external research adds value:

**Lean toward external research when:**
- Topic is high-risk: security, payments, auth, migrations
- Codebase lacks relevant local patterns
- User is exploring unfamiliar territory

**Skip external research when:**
- Strong local patterns exist (>3 direct examples)
- User clearly knows the territory
- The work is straightforward refactoring

If external research is warranted, use `web_search` for relevant best practices and framework documentation.

#### 1.3 Consolidate Research

Summarize:
- Relevant codebase patterns and file paths
- Relevant institutional learnings
- External references and best practices
- Any constraints that should shape the plan

### Phase 2: Structure the Plan

Read `.reasonix/skills/references/plan-sections.md` for the section contract.

#### 2.1 Identify Implementation Units

Group work into implementation units. Each unit:
- Has a clear deliverable
- Can be implemented and tested independently (or with clear dependencies)
- Touches a cohesive set of files
- Is sized for one focused session of work

#### 2.2 Write the Plan

Compose the plan at `docs/plans/YYYY-MM-DD-<topic>-plan.md` with:
1. Frontmatter (title, date, status, origin, depth)
2. Problem & Scope
3. Requirements Trace (when origin doc exists)
4. Key Technical Decisions
5. Implementation Units (U1, U2, ...)
6. Sequencing
7. Risks & Mitigations
8. Testing Strategy
9. Assumptions

#### 2.3 Confidence Check

Before presenting, scan for:
- Every requirement (R-ID) mapped to at least one implementation unit
- Every implementation unit has test scenarios
- Every implementation unit has file paths
- No pre-written implementation code leaked into the plan
- Risks are identified with mitigations
- Dependencies between units are explicit

### Phase 3: Present and Handoff

Present the plan summary and offer next steps using `ask_choice`:

1. **Start working** — run `/ce-work docs/plans/<date>-<topic>-plan.md` to execute
2. **Review the plan** — let me refine anything
3. **Deeper analysis** — run a deepening pass for more rigor
4. **Done for now** — I'll come back to this
