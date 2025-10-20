---
id: task-70.1
title: Implement unified service configuration schema (task-70)
status: To Do
assignee: []
created_date: '2025-10-20 13:34'
labels:
  - infrastructure
  - dx
  - refactor
dependencies: []
parent_task_id: '70'
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Implement the complete service configuration refactoring from task-70 in one shot. No hybrid/incremental migration - replace the entire old system (services.nix + media.nix) with the new unified schema in a single atomic change.

**Key Requirements:**
1. Complete cutover - no coexistence of old and new systems
2. Directory-based organization (services/media.nix, services/development.nix, etc.)
3. Compact schema with explicit container marking
4. Port conflict validation
5. Auto-generated auth/funnel/expose lists
6. Deploy to both storage and cloud hosts

**Implementation approach:**
- Create new modules/constellation/services/ directory structure
- Implement schema and validation
- Migrate ALL services to new format
- Remove old services.nix and media.nix files
- Update imports
- Build and deploy in one go

**Reference:** See task-70 for complete plan and design decisions
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 All services migrated to new schema format
- [ ] #2 Old services.nix and media.nix removed
- [ ] #3 Both storage and cloud build successfully
- [ ] #4 Port conflict validation working
- [ ] #5 No hybrid state - complete cutover
- [ ] #6 All services accessible through gateway after deployment
<!-- AC:END -->
