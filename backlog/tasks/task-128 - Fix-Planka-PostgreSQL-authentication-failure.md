---
id: task-128
title: Fix Planka PostgreSQL authentication failure
status: Done
assignee: []
created_date: '2025-11-02 02:43'
updated_date: '2025-11-02 02:57'
labels:
  - bug
  - cloud
  - database
  - planka
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Planka kanban board service on cloud host is failing to start due to PostgreSQL authentication errors. The service fails with "password authentication failed for user 'planka'".

**Current Status:**
- Service: docker-planka.service
- Error: `password authentication failed for user "planka"`
- Impact: Planka is inaccessible (HTTP 502)

**Investigation Needed:**
1. Verify the PostgreSQL planka user exists
2. Check if the password in the database matches the secret in /run/agenix.d/planka-db-password
3. Verify the systemd service's preStart script is correctly setting the password
4. Check if PostgreSQL's pg_hba.conf allows password authentication for the planka user

**Context:**
- Service configuration: hosts/cloud/services/planka.nix
- Secrets: secrets/planka-db-password.age and secrets/planka-secret-key.age
- Database setup happens in systemd.services.postgresql.postStart
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Planka service starts successfully without authentication errors
- [x] #2 Planka web interface is accessible at https://planka.arsfeld.dev
- [x] #3 PostgreSQL planka user can authenticate with the configured password
- [x] #4 Service remains stable after restart
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Root Cause

The PostgreSQL authentication failure was caused by two issues:

1. **Missing TCP/IP configuration**: PostgreSQL wasn't configured to accept TCP/IP connections from the containerized Planka service
2. **Secret permission issue**: The planka-db-password secret was owned by root:root, preventing the postgres user from reading it during the postStart script

## Solution Implemented

### 1. Enable TCP/IP connections (hosts/cloud/services/planka.nix:72)
```nix
services.postgresql = {
  enable = true;
  enableTCPIP = true;  # Added
  # ...
}
```

### 2. Configure authentication rules (hosts/cloud/services/planka.nix:81-84)
```nix
authentication = lib.mkAfter ''
  host ${cfg.database.name} ${cfg.database.user} 127.0.0.1/32 scram-sha-256
  host ${cfg.database.name} ${cfg.database.user} ::1/128 scram-sha-256
'';
```

### 3. Fix secret ownership (hosts/cloud/services/planka.nix:158-160)
```nix
age.secrets.planka-db-password = {
  file = ../../../secrets/planka-db-password.age;
  owner = "postgres";    # Changed from "root"
  group = "postgres";    # Changed from "root"
  mode = "0400";         # Added
};
```

## Verification

- Service status: active (running)
- HTTP 200 response on both localhost:1337 and https://planka.arsfeld.dev
- No authentication errors in logs
- PostgreSQL postStart script successfully sets password
<!-- SECTION:NOTES:END -->
