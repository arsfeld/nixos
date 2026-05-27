---
name: ce-compound
description: "Document a recently solved problem to compound your team's knowledge. Captures solutions while context is fresh, creating structured documentation in docs/solutions/ with YAML frontmatter for searchability. Use after fixing a bug, resolving a tricky config issue, or discovering a pattern worth recording."
argument-hint: "[optional: brief context about what was solved]"
---

# Compound — Document Solved Problems

Captures problem solutions while context is fresh, creating structured documentation in `docs/solutions/` with YAML frontmatter for searchability and future reference.

**Why "compound"?** Each documented solution compounds your team's knowledge. The first time you solve a problem takes research. Document it, and the next occurrence takes minutes.

## Core Principles

1. **One file, one solution.** The output is a single markdown file in `docs/solutions/<category>/`.
2. **Bug or knowledge.** Every entry is classified as either a bug fix (what broke + how it was fixed) or knowledge (a pattern, practice, or gotcha worth recording).
3. **Frontmatter for searchability.** YAML frontmatter with `tags`, `module`, `problem_type` makes solutions discoverable by agents and humans.
4. **What didn't work matters.** Failed investigation attempts are as valuable as the solution — they prevent others from repeating dead ends.

## Usage

```
/ce-compound                    # Document the most recent fix from conversation
/ce-compound [brief context]    # Provide additional context hint
```

## Execution Flow

### Phase 0: Assess

Check if the problem is worth documenting:
- Is this non-trivial? (Skip simple typos, one-line obvious fixes)
- Has the solution been verified working?
- Would someone else hit this again?

If the problem doesn't meet the bar, say so and suggest skipping. If there's enough substance, proceed.

### Phase 1: Research & Classify

#### 1.1 Extract from conversation
Review the conversation history. Identify:
- What was the problem? (symptoms, error messages, conditions)
- What was tried that didn't work? (dead ends are valuable)
- What was the root cause?
- What was the fix? (code changes, config changes, process changes)
- How can this be prevented in the future?

#### 1.2 Classify

Read `.reasonix/skills/references/compound-schema.yaml` and `.reasonix/skills/references/compound-yaml-schema.md`.

Determine:
- **Track**: `bug` (something broke and was fixed) or `knowledge` (pattern, practice, gotcha)
- **problem_type**: choose the best match from the schema
- **category**: the directory from the category mapping
- **tags**: 2-5 searchable keywords
- **filename**: `[sanitized-problem-slug].md` — no date prefix

#### 1.3 Check for existing docs

Search `docs/solutions/` for related documentation using `search_content` with keywords from the problem. If an existing doc covers the same problem and solution:
- **High overlap** (same problem, root cause, solution): Update the existing doc with fresher context rather than creating a duplicate.
- **Moderate overlap** (same area, different angle): Create the new doc, note the relationship.
- **Low/none**: Create the new doc normally.

### Phase 2: Write

Read `.reasonix/skills/references/compound-resolution-template.md` for the section structure.

1. Assemble the YAML frontmatter using the validated fields from Phase 1
2. Fill in the body sections according to the track template
3. Create the category directory if needed: `mkdir -p docs/solutions/<category>/`
4. Write the file: `docs/solutions/<category>/<filename>.md`

**YAML safety:** Quote string values containing `:` or `#`. See the safety rules in `compound-yaml-schema.md`.

### Phase 3: Discoverability Check

After writing, check whether the project's instruction files (CLAUDE.md, AGENTS.md) would lead an agent to discover `docs/solutions/`. If not, note it briefly:

> Tip: Your instruction files don't surface `docs/solutions/` to agents. A brief mention helps future agents discover these learnings.

If the user wants to fix this, propose a 1-2 line addition to the appropriate instruction file.

### Phase 4: Handoff

Confirm what was written and suggest next steps:

```
✓ Documentation complete

File: docs/solutions/<category>/<filename>.md
Track: <bug | knowledge>
Category: <category>

Next: run /ce-code-review to review related changes, or /ce-compound again after the next fix.
```

## What This Skill Does Not Do

- Does not fix bugs — the problem should already be solved
- Does not run tests or verify the fix
- Does not commit or push changes
- Does not replace `ce-code-review` — this captures institutional knowledge, not code quality
