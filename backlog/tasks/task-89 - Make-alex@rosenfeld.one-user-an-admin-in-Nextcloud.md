---
id: task-89
title: Make alex@rosenfeld.one user an admin in Nextcloud
status: Done
assignee: []
created_date: '2025-10-21 18:20'
updated_date: '2025-10-21 18:22'
labels:
  - nextcloud
  - user-management
  - admin
  - oidc
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
## Goal

Grant administrative privileges to the alex@rosenfeld.one user account in Nextcloud.

## Context

- Nextcloud OIDC integration is now working (task-88)
- Users can authenticate via Authelia using LDAP credentials
- When logging in via OIDC, user accounts are auto-created
- Admin privileges need to be granted to manage Nextcloud settings

## Implementation Options

### Option 1: OCC Command (Recommended)
Use the nextcloud-occ command to add user to admin group:
```bash
ssh storage.bat-boa.ts.net "sudo -u nextcloud nextcloud-occ group:adduser admin alex@rosenfeld.one"
```

### Option 2: Web UI
1. Log in to Nextcloud with the initial admin account
2. Navigate to Settings → Users
3. Find alex@rosenfeld.one user
4. Add to "admin" group

## Prerequisites

- User must log in at least once via OIDC to create the account
- Verify the exact username format used by OIDC (might be "alex", "alex@rosenfeld.one", or "arosenfeld")

## Verification Steps

1. Check current user groups: `occ user:info alex@rosenfeld.one`
2. Add to admin group: `occ group:adduser admin <username>`
3. Verify admin access in web UI (Settings menu should show admin options)
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 alex@rosenfeld.one user has admin privileges in Nextcloud
- [x] #2 Can access Nextcloud admin settings and user management
- [x] #3 Admin group membership verified via OCC command
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Implementation Summary

Successfully granted admin privileges to alex@rosenfeld.one user.

**Username Format**: User is created as "alex" (not full email) when logging in via OIDC

**Commands Used**:
1. Listed users: `nextcloud-occ user:list` → Found "alex" user
2. Checked current groups: `nextcloud-occ user:info alex` → No groups initially
3. Added to admin group: `nextcloud-occ group:adduser admin alex` → Success
4. Verified membership: `nextcloud-occ user:info alex` → Now shows "admin" in groups

**Status**: User "alex" now has admin privileges and can access all Nextcloud admin settings.
<!-- SECTION:NOTES:END -->
