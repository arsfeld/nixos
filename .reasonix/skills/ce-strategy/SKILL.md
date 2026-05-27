---
name: ce-strategy
description: "Create or maintain STRATEGY.md — the product's target problem, approach, users, key metrics, and tracks. Use when starting a new project, updating direction, or when downstream skills need upstream grounding. Triggers on prompts like 'write our strategy', 'update the roadmap', 'what are we working on'."
argument-hint: "[optional: section to revisit, e.g. 'metrics' or 'approach']"
---

# Product Strategy

`ce-strategy` produces and maintains `STRATEGY.md` — a short, durable anchor document that captures what the product is, who it serves, how it succeeds, and where the team is investing. It lives at the repo root. Downstream skills (`ce-brainstorm`, `ce-plan`) read it as grounding when it exists.

The document is short and structured on purpose. Good answers to a handful of sharp questions produce a better strategy than any amount of prose. This skill asks those questions, pushes back on weak answers, and writes the doc.

## Core Principles

1. **Anchor, not plan.** Strategy is what the product is and why. Features belong in `ce-brainstorm`; schedules belong in the issue tracker.
2. **Rigor in the questions, not the headings.** The section headers are plain English. The interview questions enforce strategy discipline.
3. **Short is a feature.** The template is constrained. Adding sections costs more than it looks like. Push back on expansion.
4. **Durable across runs.** This skill is rerunnable. On a second run it updates in place, preserves what is working, and only challenges sections that look stale or weak.

## Interaction Method

Use `ask_choice` for all user decisions. Ask one question at a time. For substantive answers (problem, approach, persona), use `allowCustom: true` so the user can write freely.

## Focus Hint

<focus_hint> #$ARGUMENTS </focus_hint>

Interpret any argument as an optional focus: a section name to revisit (`metrics`, `approach`, `tracks`) or a scope hint. With no argument, proceed open-ended and let the file state decide the path.

## Execution Flow

### Phase 0: Route by File State

Read `STRATEGY.md` using `read_file`.

- **File does not exist** → First run. Go to Phase 1.
- **File exists and argument names a specific section** → Targeted update. Go to Phase 2.
- **File exists, no argument** → Ask which section(s) to revisit, then Phase 2.

Announce the path: "Strategy doc not found — let's write it." or "Found existing strategy — let's review and update."

### Phase 1: First-Run Interview

Read `.reasonix/skills/references/strategy-interview.md`. This load is non-optional — the pushback rules, anti-pattern examples, and quality bar for each section live there.

Run the interview in section order:

1. Target problem
2. Our approach
3. Who it's for
4. Key metrics
5. Tracks
6. Milestones (optional)
7. Not working on (optional)
8. Marketing (optional)

For each section, ask the opening question, apply the pushback rules, and capture the final answer in the user's own language. Do not skip the pushback step — it is the core of the skill. Two rounds of pushback per section maximum; capture what the user has given after that and note the section is worth revisiting.

When all required sections (1-5) are captured, read `.reasonix/skills/references/strategy-template.md`, fill it in, and present the full draft before writing. Offer one round of edits. Then write to `STRATEGY.md`.

### Phase 2: Update Run

Read the existing `STRATEGY.md` thoroughly. Summarize current state in 3-5 lines so the user sees what is on file.

If the argument named a specific section, jump to that section in `strategy-interview.md`. Preserve all other sections exactly. Apply pushback as if this were a first run.

If no specific target, use `ask_choice` to ask which section to revisit:
- "Target problem"
- "Our approach"
- "Who it's for"
- "Metrics, tracks, or other"

For each revisited section, re-interview with full pushback. For sections confirmed still accurate, leave untouched. Update `last_updated` to today's ISO date.

Write the updated doc back to `STRATEGY.md`.

### Phase 3: Downstream Handoff

After writing, note where the file lives and that `ce-brainstorm` and `ce-plan` will pick it up as grounding on their next run.

## What This Skill Does Not Do

- Does not update the issue tracker or reconcile in-flight work.
- Does not prioritize the backlog.
- Does not write product requirements or implementation plans — those are `ce-brainstorm` and `ce-plan`.
- Does not compute metric values. It records which metrics matter and where they live, not what they read today.
