---
id: task-78
title: Align storage bridge MAC with router reservation
status: Done
assignee: []
created_date: '2025-10-21 02:43'
updated_date: '2025-10-21 02:45'
labels: []
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ensure the storage bridge interface on the relevant host uses the MAC address that is reserved for it on the router. Update the NixOS configuration so the interface is pinned to that MAC and verify the router reservation remains consistent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Interface definition sets the storage bridge MAC address to match the router reservation.
- [x] #2 Configuration builds successfully with the updated MAC settings.
- [x] #3 Documentation or comments note the source of the reserved MAC address for future reference.
<!-- AC:END -->
