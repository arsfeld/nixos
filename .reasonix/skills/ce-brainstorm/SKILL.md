---
name: ce-brainstorm
description: "Explore requirements and approaches through collaborative dialogue, then write a right-sized requirements document. Use when the user says 'let's brainstorm', 'what should we build', 'help me think through X', or presents a vague or ambitious feature request."
argument-hint: "[feature idea or problem to explore]"
---

# Brainstorm a Feature or Improvement

Brainstorming helps answer **WHAT** to build through collaborative dialogue. It precedes `ce-plan`, which answers **HOW** to build it.

The durable output is a **requirements document** in `docs/brainstorms/YYYY-MM-DD-<topic>-requirements.md`.

This skill does not implement code. It explores, clarifies, and documents decisions for later planning or execution.

**All file references in generated documents must use repo-relative paths, never absolute paths.**

## Core Principles

1. **Assess scope first** — Match ceremony to the size and ambiguity of the work.
2. **Be a thinking partner** — Suggest alternatives, challenge assumptions, explore what-ifs.
3. **Resolve product decisions here** — User-facing behavior, scope, and success criteria belong here. Implementation details belong in planning.
4. **Keep implementation out of the requirements doc** — No libraries, schemas, endpoints, or file layouts unless the brainstorm is inherently about a technical decision.
5. **Right-size the artifact** — Simple work gets a compact doc. Larger work gets more structure.
6. **Apply YAGNI to carrying cost, not coding effort** — Prefer the simplest approach. Low-cost polish is worth including; speculative complexity is not.

## Interaction Rules

1. **Ask one question at a time** — One question per turn. Stacking questions produces diluted answers.
2. **Use `ask_choice` for narrowing decisions** — When the user needs to pick a direction, priority, or next step.
3. **Use open-ended questions when the answer is genuinely narrative** — When options would bias the answer or the question is diagnostic.
4. **Don't narrate the form** — Just ask the question. The tool choice should be invisible.

## Feature Description

<feature_description> #$ARGUMENTS </feature_description>

**If empty, ask:** "What would you like to explore? Describe the feature, problem, or improvement you're thinking about."

Do not proceed until you have a feature description.

## Execution Flow

### Phase 0: Assess and Route

#### 0.1 Resume Existing Work

If the user references an existing brainstorm topic or there's an obvious recent matching `*-requirements.md` in `docs/brainstorms/`:
- Read the document
- Confirm: "Found an existing requirements doc for [topic]. Continue from this, or start fresh?"
- If resuming, summarize current state and update the existing document.

#### 0.2 Assess Whether Brainstorming Is Needed

**Clear requirements indicators:**
- Specific acceptance criteria provided
- Referenced existing patterns to follow
- Described exact expected behavior
- Constrained, well-defined scope

If requirements are already clear, keep it brief. Confirm understanding, present next-step options, skip to Phase 3 for a short doc. Skip Phase 1.1 and 1.2 entirely.

#### 0.3 Assess Scope

Classify the work:
- **Lightweight** — small, well-bounded, low ambiguity
- **Standard** — normal feature or bounded refactor with decisions to make
- **Deep** — cross-cutting, strategic, or highly ambiguous

### Phase 1: Understand the Idea

#### 1.1 Context Scan

Match depth to scope:

**Lightweight** — Search for the topic, check if something similar exists, move on.

**Standard and Deep** — Two passes:
1. **Constraint Check** — Read `AGENTS.md`, `CLAUDE.md`, and `STRATEGY.md` (if it exists) for workflow, product, or scope constraints.
2. **Topic Scan** — Search for relevant terms. Read the most relevant existing artifact (brainstorm, plan, spec). Skim adjacent examples.

Two rules:
1. **Verify before claiming** — When the brainstorm touches checkable infrastructure, read the relevant source files. Any claim of absence must be verified or labeled as an unverified assumption.
2. **Defer design decisions to planning** — Implementation details belong in `ce-plan`, not here.

#### 1.2 Product Pressure Test

Before generating approaches, scan for rigor gaps. Raise only the gaps that actually exist during dialogue — not a pre-flight gauntlet.

**Standard — scan for these gaps:**

- **Evidence gap**: The opening asserts want/need without observable evidence. Ask: "What's the most concrete thing someone's already done about this?"
- **Specificity gap**: The beneficiary is too abstract. Ask: "Can you name a specific person or narrow segment, and what changes for them when this ships?"
- **Counterfactual gap**: No mention of current workarounds. Ask: "What do people do today when this problem arises, and what does it cost them?"
- **Attachment gap**: The opening treats a solution shape as the thing being built. Ask: "What's the smallest version that still delivers real value?"

**Deep — add:**
- Is this a local patch, or does it move the broader system toward where it wants to be?

#### 1.3 Collaborative Dialogue

Follow the Interaction Rules. Guidelines:
- Start broad (problem, users, value) then narrow (constraints, exclusions, edge cases)
- Make requirements concrete enough that planning won't need to invent behavior
- Surface dependencies only when they materially affect scope
- Bring ideas, alternatives, and challenges — don't just interview

**Before exiting Phase 1.3: integration check.** Mentally combine what the user has said and surface non-obvious consequences the dialogue hasn't probed.

Exit when the idea is clear and no integration-check questions remain, or the user explicitly wants to proceed.

### Phase 2: Explore Approaches

If multiple plausible directions remain, propose **2-3 concrete approaches**. Otherwise state the recommended direction directly.

Use at least one non-obvious angle — inversion, constraint removal, or analogy from another domain.

For each approach: brief description, pros/cons, key risks, when it's best suited.

After presenting all approaches, state your recommendation and explain why. Prefer simpler solutions; don't reject low-cost, high-value polish.

If one approach is clearly best, skip the menu and state the recommendation directly.

### Phase 2.5: Synthesis Summary

Surface a scoping synthesis before writing the doc — the user's last chance to correct scope.

**Path A (no blocking questions AND Lightweight):** Emit "What we're building" in 1-3 sentences, then proceed to Phase 3 in the same turn.

**Path B (any blocking questions OR Standard/Deep):** Full scoping synthesis with confirmation gate. Present:
- What the plan will target
- What it will not
- Call-outs (specific forks where user input changes the plan)

Wait for confirmation before proceeding to Phase 3.

### Phase 3: Capture the Requirements

Read `.reasonix/skills/references/brainstorm-sections.md` for the section contract.

Write to `docs/brainstorms/YYYY-MM-DD-<topic>-requirements.md`. Confirm with the absolute path.

Skip document creation when the user only needs brief alignment and decisions can flow downstream without an artifact.

### Phase 4: Handoff

Present next-step options using `ask_choice`:

1. **Plan it** — run `/ce-plan docs/brainstorms/<date>-<topic>-requirements.md`
2. **Start working** — begin implementation directly
3. **Review the doc** — let me refine anything
4. **Done for now** — I'll come back to this

Execute the selected option immediately.
