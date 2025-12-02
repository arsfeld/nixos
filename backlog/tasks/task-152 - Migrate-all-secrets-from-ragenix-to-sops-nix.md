---
id: task-152
title: Migrate all secrets from ragenix to sops-nix
status: To Do
assignee: []
created_date: '2025-11-30 18:12'
labels:
  - infrastructure
  - secrets
  - migration
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Complete the transition from legacy ragenix secret management to sops-nix across all hosts.

## Current State
- **sops-nix**: Only `cloud` host is partially migrated (4 secrets in `secrets/sops/cloud.yaml`)
- **ragenix**: 54 `.age` files in `secrets/` covering multiple hosts

## Hosts to Migrate
1. **cloud** - Partially done, ~16 secrets still in ragenix
2. **storage** - ~25 secrets to migrate
3. **raider** - ~5 secrets (harmonia, stash, github-token)
4. **cottage** - ~2 secrets (restic)
5. **r2s/raspi3/router** - Minor hosts, shared secrets only

## Benefits of sops-nix
- YAML format is more readable and editable
- Better multi-key support per file
- Easier key rotation
- More active upstream development
- Standard tooling (sops CLI)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All hosts use sops-nix for secret management
- [ ] #2 All ragenix .age files removed from secrets/
- [ ] #3 secrets/secrets.nix file removed
- [ ] #4 .sops.yaml contains all host keys
- [ ] #5 Each host has its own sops YAML file or uses common.yaml
- [ ] #6 All services using secrets continue to work after migration
- [ ] #7 Documentation in CLAUDE.md updated to remove ragenix references
<!-- AC:END -->
