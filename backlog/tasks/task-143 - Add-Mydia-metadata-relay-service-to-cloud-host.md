---
id: task-143
title: Add Mydia metadata-relay service to cloud host
status: Done
assignee:
  - Claude
created_date: '2025-11-12 18:38'
updated_date: '2025-11-12 19:34'
labels:
  - cloud
  - media
  - service
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deploy the Mydia metadata-relay service to provide centralized metadata caching and API aggregation for media services. This service acts as a caching layer between media applications and external metadata providers (TMDB, TVDB), reducing API calls and improving response times across the media stack.

The service uses Redis for caching and aggregates metadata from multiple sources, making it easier for media applications to retrieve and display movie/TV show information.

Repository: https://github.com/getmydia/mydia/tree/master/metadata-relay

Note: TMDB and TVDB API keys will be stored as secrets using sops-nix.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Service is deployed and running on cloud host
- [x] #2 Redis is configured and accessible to the service
- [x] #3 TMDB API integration is functional with provided key
- [x] #4 TVDB API integration is functional with provided key
- [x] #5 Service follows constellation module patterns for containerized services
- [x] #6 Service is accessible to other media applications that need metadata
- [x] #7 Configuration is properly managed (secrets stored in sops-nix)
- [x] #8 Service restarts automatically on failure
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Implementation Plan (Updated)

### 1. Research Phase (COMPLETED)
- Reviewed Mydia metadata-relay repository to understand configuration requirements
- Identified required environment variables: TMDB_API_KEY, TVDB_API_KEY, REDIS_URL (optional), PORT
- Examined existing constellation patterns in media.nix and services.nix
- Confirmed sops-nix configuration for cloud host secrets
- User provided API keys for TMDB and TVDB

### 2. Configure Redis via NixOS Module
**File:** `hosts/cloud/services/utility.nix` (or new file)
- Add `services.redis.servers.metadata-relay` configuration
- Bind to localhost (127.0.0.1)
- Use port 6379 or another available port
- Enable persistence

### 3. Add Metadata-Relay Container
**File:** `modules/constellation/media.nix`
- Add `metadata-relay` container to `cloudServices` section
- Use image: `ghcr.io/getmydia/mydia/metadata-relay`
- Set `listenPort = 4001`
- Configure environment variables:
  - PORT=4001
  - REDIS_URL=redis://localhost:6379
- Configure environmentFiles to load secrets
- Set `bypassAuth = true` (API service)
- Use network = "host" to access host Redis

### 4. Configure Secrets
**File:** `secrets/sops/cloud.yaml`
- Add metadata-relay-env secret with TMDB_API_KEY and TVDB_API_KEY
- Use sops to encrypt the file

**File:** `hosts/cloud/configuration.nix`
- Add sops.secrets.metadata-relay-env configuration

### 5. Register in Service Gateway
**File:** `modules/constellation/services.nix`
- Add `metadata-relay = 4001` to cloud services section
- Add to `bypassAuth` list (API service)
- Service will be accessible at metadata-relay.arsfeld.dev

### 6. Deploy and Verify
- Format code with `just fmt`
- Build configuration: `nix build .#nixosConfigurations.cloud.config.system.build.toplevel`
- Deploy to cloud: `just deploy cloud`
- Verify Redis and metadata-relay services are running
- Test metadata API at metadata-relay.arsfeld.dev

## Key Decisions
- Using NixOS Redis module (services.redis.servers) instead of containerized Redis
- Using port 4001 for the service
- Using network = "host" to allow container to access localhost Redis
- Service accessible via metadata-relay.arsfeld.dev
- Using sops-nix for secret management on cloud host

## Files to Modify
1. `hosts/cloud/services/utility.nix` - Add Redis configuration
2. `modules/constellation/media.nix` - Add container
3. `secrets/sops/cloud.yaml` - Add API keys
4. `hosts/cloud/configuration.nix` - Add secret configuration
5. `modules/constellation/services.nix` - Add service registration
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Container image: ghcr.io/getmydia/mydia/metadata-relay

## Deployment Summary

**Deployment Date:** 2025-11-12

**Services Deployed:**
- Redis instance: redis-metadata-relay.service (port 6380)
- Metadata-relay container: docker-metadata-relay.service (port 4001)

**Access Points:**
- Direct: http://localhost:4001 (on cloud host)
- Tailscale: http://cloud.bat-boa.ts.net:4001
- Gateway: https://metadata-relay.arsfeld.dev

**API Endpoints Verified:**
- Health: GET /health ✓
- TMDB Movie Search: GET /tmdb/movies/search?query=Matrix ✓
- TVDB Series Search: GET /tvdb/search?query=Breaking+Bad ✓

**Configuration:**
- Redis: Persistent storage with save points (900s/1 key, 300s/10 keys, 60s/10000 keys)
- Network: Host mode for localhost Redis access
- Secrets: TMDB_API_KEY and TVDB_API_KEY stored in sops-nix
- Authentication: Bypassed (API service for internal use)

**TVDB Authentication:** Successfully authenticated, token expires 2025-12-13 04:52:42Z

## Domain Configuration Issue & Resolution

**Problem:** Service was initially configured for `arsfeld.one` (default domain) but user's DNS wildcard was configured for `*.arsfeld.dev`, causing 404 errors from Cloudflare.

**Root Cause:** 
- `media.config.domain` defaults to `arsfeld.one` in modules/media/config.nix
- User has `*.arsfeld.dev` CNAME configured in Cloudflare DNS
- Service was accessible via Tailscale but not public domain

**Resolution:**
1. Set `media.config.domain = "arsfeld.dev"` in hosts/cloud/configuration.nix
2. Disabled `constellation.sites.arsfeld-dev.enable` to prevent Caddy conflict
   - This module creates a wildcard redirect that conflicts with media services
3. Redeployed to cloud host

**Final URLs:**
- Health: https://metadata-relay.arsfeld.dev/health ✓
- Stats: https://metadata-relay.arsfeld.dev/stats ✓
- TMDB Search: https://metadata-relay.arsfeld.dev/tmdb/movies/search?query=... ✓
- TVDB Search: https://metadata-relay.arsfeld.dev/tvdb/search?query=... ✓

All endpoints now accessible via public domain with proper TLS.
<!-- SECTION:NOTES:END -->
