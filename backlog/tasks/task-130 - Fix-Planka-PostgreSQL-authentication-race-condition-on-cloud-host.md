---
id: task-130
title: Fix Planka PostgreSQL authentication race condition on cloud host
status: Done
assignee: []
created_date: '2025-11-02 11:53'
updated_date: '2025-11-02 11:53'
labels:
  - bug
  - cloud
  - planka
  - postgresql
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Planka service was experiencing intermittent startup failures with PostgreSQL authentication errors. The docker-planka.service had no systemd dependency on postgresql.service, causing it to sometimes start before PostgreSQL finished initializing and setting the password.

Fixed by adding proper systemd dependencies to hosts/cloud/services/planka.nix:
- requires = ["postgresql.service"]
- after = ["postgresql.service"]

This ensures Planka waits for PostgreSQL to be fully ready before attempting to connect.

Commit: 98d26aa
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 PostgreSQL service dependency added to docker-planka.service
- [x] #2 Planka service starts successfully after PostgreSQL is ready
- [x] #3 No more authentication failures on startup
- [x] #4 Fix committed to repository
<!-- AC:END -->
