---
id: task-80
title: Investigate how to better integrate Dex with Authelia
status: Done
assignee: []
created_date: '2025-10-21 03:29'
updated_date: '2025-10-21 03:31'
labels:
  - investigation
  - authentication
  - dex
  - authelia
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Currently, the system uses both Dex (for OIDC authentication) and Authelia (for authentication gateway). There may be opportunities to improve the integration between these two components to provide a more seamless authentication experience.

This task involves researching:
- Current integration patterns between Dex and Authelia
- How Dex is currently configured and what services use it
- How Authelia is currently configured and what it protects
- Potential improvements or alternative architectures
- Whether one could replace the other or if they serve complementary purposes
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Document current state of Dex configuration and usage
- [x] #2 Document current state of Authelia configuration and usage
- [x] #3 Identify integration points and potential improvements
- [x] #4 Provide recommendation on how to proceed (improve integration, replace one with the other, or keep as-is with justification)
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
## Investigation Summary

Based on comprehensive analysis of the codebase, here are the findings:

## 1. Current State of Dex Configuration

**Location**: `hosts/cloud/services/auth.nix:20-89`

**Purpose**: OIDC Provider for applications requiring OAuth2/OpenID Connect authentication

**Configuration**:
- **Issuer URL**: https://rosenfeld.one
- **Storage**: SQLite at /var/lib/dex/dex.db
- **Port**: Dynamically assigned via services.dex.port
- **LDAP Connector**: Connects to LLDAP at cloud.bat-boa.ts.net:3890
- **Static Clients**: 
  1. **Tailscale** - OAuth integration for network access
  2. **Qui** - qBittorrent web UI OIDC authentication (added in task-79)

**LDAP Integration**:
```yaml
baseDN: ou=people,dc=rosenfeld,dc=one
username: uid
groups: ou=groups,dc=rosenfeld,dc=one
filter: (objectClass=groupOfUniqueNames)
```

**Key Characteristics**:
- Provides standard OIDC/OAuth2 authentication
- Designed for applications with built-in OIDC support
- No session management (stateless tokens)
- No 2FA/MFA capabilities
- Lightweight - only handles token issuance

## 2. Current State of Authelia Configuration

**Location**: `hosts/cloud/services/auth.nix:103-201`

**Purpose**: Authentication gateway/portal providing SSO and access control for services

**Configuration**:
- **Domain**: auth.arsfeld.one (authentication portal)
- **Session Domain**: arsfeld.one (wildcard for all services)
- **Port**: Dynamically assigned via services.auth.port
- **LDAP Backend**: Connects to LLDAP at 127.0.0.1:3890
- **Session Storage**: Redis with Unix socket
- **User Storage**: SQLite at /var/lib/authelia-*/db.sqlite3

**Features**:
- **Forward Auth**: Integrates with Caddy reverse proxy
- **Session Management**: 7-day sessions, 45min inactivity, 1-month remember-me
- **2FA/MFA**: TOTP support
- **Access Control**: Fine-grained rules for path-based bypasses
- **User Headers**: Injects Remote-User, Remote-Groups, Remote-Name, Remote-Email

**Access Control Rules** (examples from auth.nix:131-170):
- Transmission RPC endpoint bypass
- *arr services API endpoint bypass
- Stash streaming bypass
- Yarr Fever API bypass

**Key Characteristics**:
- Provides authentication portal with login UI
- Stateful session management
- 2FA/MFA capabilities
- Path-based access control
- Header injection for downstream services

## 3. Integration Points and Current Architecture

**Shared Components**:
- Both connect to same LLDAP instance (dc=rosenfeld,dc=one)
- Both authenticate against same user base
- Both run on cloud host

**Gateway Flow** (from `modules/media/gateway.nix`):
```
User → Caddy → Authelia (forward_auth) → Backend Service
                  ↓
               LLDAP
```

**OIDC Flow** (for Dex clients like Tailscale and Qui):
```
User → Application → Dex → LLDAP
                      ↓
                   Token
```

**Current Usage Patterns**:

1. **Services using Authelia** (default for all services):
   - All services in constellation/services.nix unless in bypassAuth list
   - Uses session cookies for authentication
   - Accessed via *.arsfeld.one domains

2. **Services using Dex OIDC**:
   - Tailscale (network authentication)
   - Qui (qBittorrent web UI)
   - Both have native OIDC support

3. **Services bypassing authentication** (from services.nix:97-120):
   - Services with built-in auth: attic, audiobookshelf, grafana, immich, jellyfin, gitea, etc.
   - These are marked `bypassAuth = true` but still go through Caddy gateway

## 4. Potential Improvements

### Option A: Expand Dex OIDC Usage (RECOMMENDED)

**Services that could use OIDC instead of Authelia**:
- **Grafana**: Already bypasses Authelia, supports OIDC
- **Gitea**: Already bypasses Authelia, supports OIDC
- **Nextcloud**: Has user_oidc app (seen in files.nix:96)
- **Immich**: Supports OIDC authentication
- **n8n**: Supports OIDC authentication

**Benefits**:
- Native application integration (better UX)
- Stateless authentication (reduced Redis load)
- Proper logout support
- Standard OAuth2 scopes and claims
- Better mobile app support

**Drawbacks**:
- No centralized 2FA (each app manages MFA)
- More configuration per service
- Not all services support OIDC

### Option B: Use Authelia as OIDC Provider

**Approach**: Configure Authelia as OIDC provider instead of using Dex

**Status**: Authelia v4.38+ supports OIDC provider functionality

**Benefits**:
- Single authentication system
- 2FA for OIDC clients
- Unified access control

**Drawbacks**:
- Authelia's OIDC is newer/less mature than Dex
- Would need migration of existing Dex clients (Tailscale, Qui)
- More complex configuration

### Option C: Keep Current Architecture with Clear Role Separation (RECOMMENDED)

**Dex Role**: OIDC provider for:
- Services with native OIDC support
- External integrations (Tailscale, etc.)
- Modern applications preferring token-based auth

**Authelia Role**: Gateway authentication for:
- Services without OIDC support
- Legacy services
- Services requiring centralized 2FA
- Services needing path-based access control

**Improvements**:
1. Document which services should use which system
2. Gradually migrate OIDC-capable services from Authelia to Dex
3. Keep Authelia for services requiring its unique features (2FA, access control)
4. Maintain LLDAP as single source of truth for users

## 5. Recommendation

**Recommended Approach**: **Option C - Maintain both systems with clear role separation**

**Rationale**:
1. **Complementary Strengths**: Dex excels at OIDC, Authelia excels at gateway auth + 2FA
2. **Already Working**: Current architecture is stable and proven
3. **Gradual Migration**: Can incrementally move OIDC-capable services to Dex
4. **Best of Both Worlds**: Modern apps get OIDC, legacy apps get gateway auth

**Action Items**:
1. ✅ Document current state (completed in this investigation)
2. Create migration guide for services to move from Authelia to Dex OIDC
3. Identify and prioritize services for OIDC migration (Grafana, Gitea, Nextcloud, Immich, n8n)
4. Update architecture documentation to clarify role separation
5. Consider enabling Authelia's OIDC provider as future replacement for Dex (optional)

**Alternative if simplification is priority**: **Option B - Consolidate on Authelia OIDC**
- Migrate Tailscale and Qui to Authelia OIDC
- Retire Dex
- Single authentication system
- Requires testing Authelia's OIDC with all current Dex clients
<!-- SECTION:PLAN:END -->
