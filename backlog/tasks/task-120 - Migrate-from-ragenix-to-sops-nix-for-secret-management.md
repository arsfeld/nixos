---
id: task-120
title: Migrate from ragenix to sops-nix for secret management
status: In Progress
assignee: []
created_date: '2025-10-31 19:07'
updated_date: '2025-10-31 21:11'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Replace the current ragenix-based secret management system with sops-nix. This migration should follow a phased approach: first implementing a proof of concept with a subset of secrets to validate the approach, then migrating all remaining secrets.

The current system uses ragenix (rust-based age encryption) for all secrets, defined in `secrets/secrets.nix` with encrypted files in `/secrets/*.age`. The new system should use sops-nix which provides better integration with NixOS and more flexibility in secret management.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All secrets are managed through sops-nix instead of ragenix
- [ ] #2 Secret deployment works correctly on all hosts (storage, cloud, r2s, etc.)
- [ ] #3 Services can access their secrets without issues
- [ ] #4 Documentation is updated to reflect sops-nix usage
- [ ] #5 ragenix dependencies and configuration are removed from the flake
<!-- AC:END -->
