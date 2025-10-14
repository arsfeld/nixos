---
id: task-2
title: Add missing ragenix features for better CLI automation
status: In Progress
assignee:
  - '@claude'
created_date: '2025-09-24 14:21'
updated_date: '2025-09-24 14:22'
labels:
  - nixos
  - security
  - tooling
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ragenix currently lacks features needed for non-interactive use, particularly stdin input for encryption and easy decryption of secrets. This makes it difficult to automate secret generation and management in scripts.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Research vendoring ragenix package in the NixOS configuration
- [ ] #2 Add support for stdin input when creating/editing secrets
- [ ] #3 Add support for decrypting secrets via CLI (currently only edit/rekey supported)
- [ ] #4 Ensure solution works in both interactive and non-interactive contexts
- [ ] #5 Document the new features and usage patterns
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Research current ragenix implementation and how it's packaged in nixpkgs
2. Explore vendoring options - overlay vs local package definition
3. Fork/vendor ragenix and add stdin input support for encryption
4. Add decrypt command to complement existing edit/rekey commands
5. Test both interactive (TTY) and non-interactive (pipe/redirect) usage
6. Update flake and module configuration to use vendored version
7. Document changes in CLAUDE.md and inline comments
<!-- SECTION:PLAN:END -->
