# Resolution Template — docs/solutions/ document structure

## Bug Track Template

```markdown
---
title: "[one-line problem description]"
date: YYYY-MM-DD
problem_type: [from schema]
category: [from category mapping]
tags: [keyword1, keyword2]
track: bug
symptoms: "[observable symptoms]"
root_cause: "[technical root cause]"
resolution_type: [code_fix | config_change | workaround | dependency_update | process_change]
module: "[affected module]"
severity: [critical | high | medium | low]
---

## Problem

[1-2 sentence description of the issue]

## Symptoms

[Observable symptoms: error messages, unexpected behavior, conditions that trigger it]

## What Didn't Work

[Failed investigation attempts and why they failed. This is valuable — it prevents others from repeating dead ends.]

## Solution

[The actual fix with code examples. Use before/after when applicable.]

## Why This Works

[Root cause explanation and why the solution addresses it.]

## Prevention

[Strategies to avoid recurrence: tests to add, config to change, patterns to follow. Include concrete code examples where useful.]

## Related

- [links to issues, PRs, or related solution docs]
```

## Knowledge Track Template

```markdown
---
title: "[one-line description of the guidance]"
date: YYYY-MM-DD
problem_type: [from schema]
category: [from category mapping]
tags: [keyword1, keyword2]
track: knowledge
applies_when: "[conditions where this applies]"
module: "[related module, optional]"
---

## Context

[What situation, gap, or friction prompted this guidance]

## Guidance

[The practice, pattern, or recommendation with code examples when useful]

## Why This Matters

[Rationale and impact of following or not following this guidance]

## When to Apply

[Conditions or situations where this applies]

## Examples

[Concrete before/after or usage examples showing the practice in action]

## Related

- [links to issues, PRs, or related solution docs]
```
