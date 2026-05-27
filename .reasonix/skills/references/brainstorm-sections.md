# Brainstorm Sections — Requirements Document Structure

This describes what the requirements document contains. The format (markdown) is the default for Reasonix.

## Decide Whether a Doc Is Warranted

Skip document creation when:
- The alignment was brief and decisions can flow downstream without an artifact
- The "fix" is a one-line change with no design decisions
- The user explicitly says they don't need a doc

A doc is warranted when the conversation produced durable decisions that planning should not have to re-invent.

## Document Sections

### Required (all documents)

#### Problem Statement
1-3 sentences. What problem does this solve and for whom? Concrete, not abstract.

#### Requirements
Numbered list (R1, R2, ...). Each requirement is a single testable statement. Good: "R1: Users can mute notification rules without deleting them." Bad: "R1: Improve notification management."

#### Success Criteria
How will we know this is done and working? Measurable where possible.

#### Scope Boundaries
What's in and what's out. Include:
- **In scope**: what this covers
- **Deferred for later**: things we're explicitly postponing
- **Outside this product's identity**: things we're saying no to

### Include When Material (only if the brainstorm surfaced these)

#### Actors (A-IDs)
Named user/system roles with their goals. Format: `A1: [name] — [goal]`

#### Key Flows (F-IDs)
Primary user flows. Format: `F1: [name] — [step-by-step description]`

#### Acceptance Examples (AE-IDs)
Concrete scenarios that demonstrate each requirement is met. Format: `AE1: Given [state], when [action], then [outcome]`

#### Key Decisions
Decisions made during the brainstorm that materially affect scope or behavior. Each with rationale.

#### Dependencies / Assumptions
Things this depends on (other work, external systems) and assumptions we're making.

#### Outstanding Questions
Questions not yet resolved. Mark as blocking (must resolve before planning) or deferred (can resolve during implementation).

## ID Conventions
- Use R1, R2, ... for requirements
- Use A1, A2, ... for actors
- Use F1, F2, ... for key flows
- Use AE1, AE2, ... for acceptance examples
- Keep IDs stable across document revisions

## Agency Rules
- The requirements doc describes WHAT, not HOW
- Implementation details (schemas, endpoints, file layouts) belong in the plan, not here — unless the brainstorm is about a technical/architectural decision
- All file references use repo-relative paths, never absolute paths
