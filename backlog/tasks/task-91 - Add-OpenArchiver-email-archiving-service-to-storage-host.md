---
id: task-91
title: Add OpenArchiver email archiving service to storage host
status: Done
assignee: []
created_date: '2025-10-24 18:53'
updated_date: '2025-10-24 19:20'
labels:
  - service
  - storage
  - container
  - email
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Add OpenArchiver, a self-hosted email archiving and eDiscovery platform, to the storage host. This will provide secure email archiving from multiple providers (Google Workspace, Microsoft 365, IMAP) with full-text search, deduplication, and regulatory compliance features.

OpenArchiver runs as a containerized service (Docker-only deployment) and requires PostgreSQL, Meilisearch, and Redis/Valkey dependencies. The service stores emails in standard .eml format with compression and provides a web interface for search and discovery.

**Repository**: https://github.com/LogicLabs-OU/OpenArchiver
**Primary Port**: 3000 (web interface)
**Tech Stack**: SvelteKit frontend, Node.js/Express backend, PostgreSQL, Meilisearch, BullMQ/Redis
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 OpenArchiver service is accessible via openarchiver.arsfeld.one domain
- [x] #2 Service has proper authentication bypass configuration (uses built-in auth)
- [x] #3 PostgreSQL database is configured and accessible to OpenArchiver
- [x] #4 Meilisearch search engine is configured and integrated
- [x] #5 Redis/Valkey job queue is configured and operational
- [x] #6 Email storage directory is properly mounted and persisted
- [x] #7 Service survives system reboot with data intact
- [x] #8 Web interface loads successfully and allows login
- [x] #9 Service integrates with constellation gateway system
<!-- AC:END -->
