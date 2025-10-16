# Cloudflare Tunnel (cloudflared) Migration Analysis

**Date:** 2025-10-15
**Status:** Analysis Complete
**Related Task:** task-18

## Executive Summary

This document provides a comprehensive analysis of replacing the current media gateway implementation (Caddy + tsnsrv + Authelia) with Cloudflare Tunnel (cloudflared). After thorough research and evaluation, this analysis covers feature parity, authentication strategies, migration complexity, and provides a recommendation.

**Key Finding:** While cloudflared offers a robust tunneling solution, the migration introduces significant complexity, potential vendor lock-in, and would require substantial architectural changes. The current solution provides better flexibility and control for our use case.

## Current Architecture

### Components

The current gateway implementation (`modules/media/gateway.nix`) consists of:

1. **Caddy** - Reverse proxy and HTTP server
   - Handles SSL/TLS termination with ACME/Let's Encrypt
   - Routes requests to services based on subdomain
   - Provides CORS handling and security headers
   - Custom error page handling

2. **tsnsrv** - Tailscale service exposure daemon
   - Creates ephemeral Tailscale nodes for each service
   - Provides optional Tailscale Funnel for public access
   - Integrates with Authelia for authentication
   - Bypasses authentication for Tailnet users (optional)

3. **Authelia** - Authentication and authorization service
   - LDAP integration via lldap
   - Session management with Redis
   - Fine-grained access control rules
   - Forward authentication for Caddy and tsnsrv

### Current Features

| Feature | Implementation | Location |
|---------|----------------|----------|
| SSL/TLS Management | ACME via Caddy | `modules/media/gateway.nix:143-145` |
| Authentication | Authelia forward auth | `hosts/cloud/services/auth.nix:96-187` |
| Service Discovery | Declarative NixOS configuration | `modules/constellation/services.nix:27-92` |
| Subdomain Routing | Caddy virtual hosts | `modules/media/__utils.nix:62-107` |
| Tailscale Integration | tsnsrv with funnel support | `modules/media/__utils.nix:112-130` |
| CORS Support | Caddy snippets | `modules/media/__utils.nix:169-186` |
| Error Pages | Caddy error handling | `modules/media/__utils.nix:188-196` |
| Authentication Bypass | Per-service configuration | `modules/constellation/services.nix:94-114` |
| API Endpoint Protection | Authelia access control rules | `hosts/cloud/services/auth.nix:124-163` |

### Service Configuration Pattern

Services are defined declaratively in `modules/constellation/services.nix` with:
- Host assignment (cloud/storage)
- Port mapping (automatic or explicit)
- Authentication bypass list
- CORS requirements
- Tailscale Funnel enablement

Example from `modules/constellation/media.nix:74-76`:
```nix
overseerr = {
  listenPort = 5055;
  settings.bypassAuth = true;
};
```

This generates both Caddy virtual host configuration and tsnsrv service definitions automatically.

## Cloudflare Tunnel Architecture

### How cloudflared Works

Cloudflare Tunnel creates an encrypted tunnel between your origin server and Cloudflare's edge network using outbound-only connections (no inbound ports needed).

**Architecture Flow:**
1. cloudflared daemon runs on origin server
2. Establishes outbound connections to Cloudflare edge
3. Edge receives public requests and routes through tunnel
4. cloudflared proxies to local services

### NixOS Integration

NixOS provides a built-in `services.cloudflared` module (source: `nixpkgs/nixos/modules/services/networking/cloudflared.nix`).

**Configuration Pattern:**
```nix
services.cloudflared = {
  enable = true;
  tunnels = {
    "<tunnel-uuid>" = {
      credentialsFile = "/path/to/credentials.json";
      ingress = {
        "service1.domain.com" = "http://localhost:8080";
        "service2.domain.com" = {
          service = "http://localhost:9000";
          path = "/api/*";
        };
      };
      default = "http_status:404";
    };
  };
};
```

### Cloudflare Zero Trust Components

- **Cloudflare Tunnel** - Secure connectivity layer (free for unlimited tunnels)
- **Cloudflare Access** - Authentication and authorization (free up to 50 users)
- **Cloudflare Gateway** - DNS filtering and network security (separate pricing)

## Feature Comparison Matrix

| Feature | Current Solution | cloudflared | Migration Complexity |
|---------|------------------|-------------|---------------------|
| **SSL/TLS Management** | ✅ ACME automatic | ✅ Cloudflare automatic | Low - handled by Cloudflare |
| **Authentication** | ✅ Authelia (self-hosted) | ⚠️ Cloudflare Access or external | High - requires architecture change |
| **LDAP Integration** | ✅ Direct integration | ⚠️ Via OIDC/SAML only | Medium - requires identity bridge |
| **Subdomain Routing** | ✅ Caddy virtual hosts | ✅ Ingress rules | Low - similar pattern |
| **Tailscale Integration** | ✅ Native via tsnsrv | ⚠️ Can coexist but separate | High - loses unified auth |
| **Public Access Control** | ✅ Granular via Funnel | ✅ Via Access policies | Medium - different model |
| **CORS Handling** | ✅ Caddy snippets | ✅ Via transform rules | Medium - different syntax |
| **Error Pages** | ✅ Custom proxy | ✅ Via Workers or transforms | Medium - requires setup |
| **Per-Service Auth Bypass** | ✅ Declarative config | ✅ Per-app Access policies | Medium - different structure |
| **API Endpoint Protection** | ✅ Path-based in Authelia | ✅ Path-based in Access | Low - similar capability |
| **NixOS Declarative Config** | ✅ Full integration | ✅ Module available | Low - well supported |
| **Self-Hosted** | ✅ Complete control | ❌ Relies on Cloudflare | N/A - architectural change |
| **Vendor Independence** | ✅ Open source stack | ❌ Vendor lock-in | N/A - strategic concern |
| **Cost** | ✅ Infrastructure only | ✅ Free (up to 50 users) | Low - free tier sufficient |
| **Local Network Auth** | ✅ Bypass for Tailnet | ⚠️ Requires separate config | High - needs dual setup |
| **Session Management** | ✅ Redis-backed | ✅ Cloudflare-managed | Medium - different features |
| **Zero-Config Services** | ✅ Auto-discovery | ❌ Manual tunnel config | Medium - more explicit setup |

**Legend:**
- ✅ Full support / no concerns
- ⚠️ Partial support / requires workarounds
- ❌ Not supported / significant concern

## Critical Analysis

### Blockers and Missing Features

#### 1. Tailscale Integration Complexity

**Current:** tsnsrv provides seamless integration where:
- Services are accessible via Tailscale (private)
- Same services can optionally use Funnel (public)
- Authentication bypasses for Tailnet users
- Single unified configuration

**With cloudflared:**
- Cloudflare Tunnel and Tailscale would run in parallel
- No unified authentication (users auth twice)
- Services must be explicitly configured for each path
- Potential routing conflicts

**Verdict:** ❌ **Major architectural regression** - loses the elegant unified access model

#### 2. Authentication Architecture

**Current:** Authelia provides:
- Direct LDAP integration with lldap
- Fine-grained path-based access control
- Session management with Redis
- Self-hosted with full control
- Integration with both Caddy and tsnsrv

**With cloudflared:**

Option A: Use Cloudflare Access
- ⚠️ LDAP requires OIDC bridge (Dex, Keycloak, or Authentik)
- ⚠️ Session management controlled by Cloudflare
- ⚠️ Limited customization compared to Authelia
- ✅ Integrates natively with Cloudflare Tunnel

Option B: Keep Authelia + use cloudflared
- ⚠️ Two-layer auth (Cloudflare + Authelia)
- ⚠️ More complex configuration
- ⚠️ Potential double authentication for users
- ✅ Maintains current capabilities

**Verdict:** ⚠️ **Significant compromise** - either lose features or add complexity

#### 3. Declarative Configuration

**Current:** Services defined once in `modules/constellation/services.nix`:
```nix
storage = {
  jellyfin = 8096;
  radarr = 7878;
  # ... automatically generates Caddy + tsnsrv config
};
```

**With cloudflared:**
```nix
services.cloudflared.tunnels."<uuid>".ingress = {
  "jellyfin.arsfeld.one" = "http://storage:8096";
  "radarr.arsfeld.one" = "http://storage:7878";
  # ... must manually maintain tunnel config
  # ... separate Tailscale configuration needed
};
```

**Verdict:** ⚠️ **Loss of abstraction** - more manual configuration required

## Authentication Strategy Options

### Option 1: Cloudflare Access Only

**Architecture:**
- Replace Authelia with Cloudflare Access
- Add OIDC provider (keep Dex or add Authentik)
- Migrate all access policies to Cloudflare
- Remove tsnsrv, use cloudflared exclusively

**Pros:**
- Simplified stack (fewer components)
- Cloudflare-managed sessions
- Modern UI and UX

**Cons:**
- ❌ Vendor lock-in to Cloudflare
- ❌ Less control over auth flow
- ❌ Need OIDC bridge for LDAP
- ❌ Loses Tailnet bypass feature
- ❌ Migration effort for all policies

**Effort:** High (2-3 weeks)

### Option 2: Dual Authentication (Cloudflare + Authelia)

**Architecture:**
- Keep Authelia for Tailscale services
- Use Cloudflare Access for public services
- Maintain both authentication systems

**Pros:**
- ✅ Gradual migration possible
- ✅ Maintains Tailnet bypass
- ✅ Keeps current LDAP integration

**Cons:**
- ❌ Complex dual-auth architecture
- ❌ User confusion (different auth flows)
- ❌ Doubled maintenance burden
- ❌ Potential security gaps

**Effort:** Very High (3-4 weeks)

### Option 3: Keep Authelia + cloudflared as transport

**Architecture:**
- Use cloudflared only as tunnel (like tsnsrv)
- Keep Authelia for all authentication
- Configure Authelia as forward auth for cloudflared

**Pros:**
- ✅ Minimal auth changes
- ✅ Maintains current capabilities
- ✅ Cloudflare handles SSL/routing

**Cons:**
- ⚠️ Cloudflare tunnel + Tailscale redundancy
- ⚠️ Not using Cloudflare Access (but that's ok)
- ⚠️ Similar to current architecture

**Effort:** Medium (1-2 weeks)

### Recommendation

**Option 3** is the most pragmatic if migration is necessary, but the question remains: **why migrate at all?**

## Cloudflared NixOS Configuration Approach

If proceeding with migration, the NixOS module structure would be:

### Structure

```
modules/
  media/
    cloudflared.nix       # New module replacing gateway.nix
    __utils.nix           # Update for cloudflared ingress generation
  constellation/
    services.nix          # Update to generate cloudflared configs
```

### Example Configuration

```nix
# modules/media/cloudflared.nix
{ config, lib, ... }:
with lib;
let
  cfg = config.media.cloudflared;

  # Generate ingress rules from service definitions
  generateIngress = services:
    lib.listToAttrs (
      lib.mapAttrsToList (name: service:
        lib.nameValuePair
          "${name}.${cfg.domain}"
          "http://${service.host}:${toString service.port}"
      ) (lib.filterAttrs (n: s: s.enable) services)
    );
in {
  options.media.cloudflared = {
    enable = mkEnableOption "Cloudflare Tunnel gateway";

    domain = mkOption {
      type = types.str;
      description = "Base domain for services";
    };

    tunnelId = mkOption {
      type = types.str;
      description = "Cloudflare Tunnel UUID";
    };

    credentialsFile = mkOption {
      type = types.path;
      description = "Path to tunnel credentials JSON";
    };

    services = mkOption {
      type = types.attrsOf serviceType;
      description = "Services to expose";
    };
  };

  config = mkIf cfg.enable {
    services.cloudflared = {
      enable = true;
      tunnels."${cfg.tunnelId}" = {
        inherit (cfg) credentialsFile;
        ingress = generateIngress cfg.services;
        default = "http_status:404";
      };
    };
  };
}
```

### Secrets Management

Cloudflare credentials would be managed via agenix:

```nix
# secrets/secrets.nix
age.secrets.cloudflare-tunnel-credentials = {
  file = "${self}/secrets/cloudflare-tunnel-credentials.age";
  mode = "400";
  owner = "cloudflared";
};

# hosts/storage/services.nix
media.cloudflared.credentialsFile =
  config.age.secrets.cloudflare-tunnel-credentials.path;
```

## Migration Plan with Rollback Strategy

### Prerequisites

- [ ] Cloudflare account with domain configured
- [ ] Cloudflare Tunnel created and credentials obtained
- [ ] Decision on authentication strategy (Option 1, 2, or 3)
- [ ] Test environment available

### Phase 1: Preparation (1 week)

**Week 1: Setup and Testing**

1. Create Cloudflare Tunnel
   ```bash
   cloudflared tunnel create nixos-media
   cloudflared tunnel token nixos-media
   ```

2. Encrypt credentials with agenix
   ```bash
   echo '<credentials-json>' | ragenix -e secrets/cloudflare-tunnel-credentials.age --editor -
   ```

3. Create test configuration in `modules/media/cloudflared-test.nix`

4. Deploy to test service (e.g., `yarr` on port 7070)
   ```nix
   services.cloudflared = {
     enable = true;
     tunnels."<uuid>" = {
       credentialsFile = config.age.secrets.cloudflare-tunnel-credentials.path;
       ingress = {
         "yarr-test.arsfeld.one" = "http://localhost:7070";
       };
       default = "http_status:404";
     };
   };
   ```

5. Verify functionality
   - Test public access via Cloudflare
   - Test authentication (if using Cloudflare Access)
   - Monitor performance and latency
   - Check SSL/TLS certificates

**Rollback:** Simply disable test configuration, no impact on production

### Phase 2: Parallel Deployment (1-2 weeks)

**Week 2-3: Run Both Systems**

1. Deploy cloudflared alongside existing gateway
2. Configure subset of non-critical services (10-20%)
3. Update DNS for test services to point to Cloudflare
4. Monitor for issues
   - Check logs: `journalctl -u cloudflared -f`
   - Monitor metrics: `systemctl status cloudflared`
   - Track user reports

**Rollback:** Revert DNS changes, services still available via old gateway

### Phase 3: Authentication Migration (1-2 weeks)

**Week 4-5: Auth Strategy Implementation**

If choosing Option 1 (Cloudflare Access):
1. Configure Cloudflare Access application for each service
2. Set up OIDC provider (Dex configuration)
3. Migrate Authelia access rules to Cloudflare Access policies
4. Test authentication flow thoroughly

If choosing Option 3 (Keep Authelia):
1. Configure Authelia as forward auth for cloudflared
2. Update Authelia configuration for Cloudflare origins
3. Test authentication bypass for services

**Rollback:** Keep Authelia running, revert to old gateway

### Phase 4: Full Migration (1 week)

**Week 6: Complete Transition**

1. Migrate remaining services to cloudflared
2. Update all DNS records
3. Monitor for 48-72 hours
4. Disable Caddy and tsnsrv services
5. Remove old gateway configuration

**Rollback:** Re-enable Caddy/tsnsrv, revert DNS (full rollback possible for 1 week)

### Phase 5: Cleanup (1 week)

**Week 7: Decommission Old Stack**

1. Archive old configuration files
2. Remove unused packages (Caddy, tsnsrv if not used elsewhere)
3. Update documentation
4. Remove Authelia if migrating to Cloudflare Access (not recommended)

**Rollback:** Restore from git history

### Total Timeline

**6-7 weeks** for complete migration with testing and validation

### Rollback Triggers

Immediately rollback if:
- Service availability drops below 99%
- User authentication fails for >5% of attempts
- Latency increases by >200ms for >10% of requests
- Critical service becomes unavailable
- Security incident related to new configuration

### Emergency Rollback Procedure

```bash
# 1. Revert DNS to old gateway
# (manual in Cloudflare dashboard or via API)

# 2. Disable cloudflared
just deploy storage  # with cloudflared.enable = false

# 3. Re-enable old gateway
just deploy storage  # with gateway.enable = true

# 4. Verify services are accessible
curl -I https://jellyfin.arsfeld.one
```

## Trade-offs and Analysis

### Advantages of Migration to cloudflared

1. **Simplified SSL Management**
   - No ACME configuration needed
   - Automatic certificate management by Cloudflare
   - Wildcard certificates included
   - **Impact:** Minor - current ACME setup works fine

2. **DDoS Protection**
   - Cloudflare's edge network provides DDoS mitigation
   - Rate limiting at edge
   - **Impact:** Low value - Tailscale Funnel already provides protection for public services

3. **Global CDN**
   - Content served from nearest edge location
   - Reduced latency for global users
   - **Impact:** Not applicable - services are personal use, not public CDN needs

4. **Modern UI for Access Control**
   - Cloudflare Zero Trust dashboard
   - Easier for non-technical admins
   - **Impact:** Low value - current config-as-code is preferred

5. **No Inbound Ports Required**
   - Outbound-only connections
   - Easier firewall configuration
   - **Impact:** Not applicable - already using Tailscale, no ports exposed

### Disadvantages of Migration to cloudflared

1. **Vendor Lock-in**
   - Dependent on Cloudflare infrastructure
   - Potential pricing changes (currently free)
   - Migration away becomes complex
   - **Impact:** HIGH - loss of independence

2. **Loss of Tailscale Integration**
   - No unified Tailnet + public access
   - Separate configuration for private access
   - Authentication bypass complexity
   - **Impact:** HIGH - major feature regression

3. **Reduced Control**
   - Authentication managed by third party
   - Limited customization options
   - Debugging requires Cloudflare tools
   - **Impact:** MEDIUM-HIGH - operational concern

4. **Privacy Concerns**
   - All traffic routes through Cloudflare
   - Cloudflare can inspect traffic (even if encrypted end-to-end)
   - Metadata visibility to third party
   - **Impact:** MEDIUM - personal data exposure

5. **Complexity Increase**
   - Need to maintain Cloudflare dashboard + NixOS config
   - Two places to manage access control
   - Additional learning curve
   - **Impact:** MEDIUM - operational overhead

6. **Configuration Verbosity**
   - Loss of current abstraction layer
   - Manual tunnel ingress rules per service
   - Duplicate config for Tailscale + Cloudflare
   - **Impact:** MEDIUM - developer experience

7. **Latency Introduction**
   - Extra hop via Cloudflare edge
   - Not ideal for real-time services
   - **Impact:** LOW-MEDIUM - measurable for local users

8. **Authentication Compromise**
   - Either lose Authelia features OR run dual auth
   - LDAP requires OIDC bridge
   - Session management less flexible
   - **Impact:** HIGH - functional regression

### Cost-Benefit Analysis

| Category | Current Solution | cloudflared | Delta |
|----------|------------------|-------------|-------|
| **Initial Setup** | Already done | 6-7 weeks | -6-7 weeks |
| **Ongoing Maintenance** | Low (declarative) | Medium (dual systems) | +maintenance |
| **Operational Cost** | $0 (infra only) | $0 (free tier) | No change |
| **Control/Flexibility** | Full | Limited | -control |
| **Security** | Self-hosted | Third-party trust | -privacy |
| **Features** | Complete | Requires compromise | -features |
| **Complexity** | Manageable | Higher | +complexity |

### Feature Value Assessment

Features gained by migrating:
- ✅ Cloudflare DDoS protection (low value - not needed)
- ✅ Global CDN (no value - personal use)
- ✅ Modern admin UI (low value - prefer code)

Features lost or compromised:
- ❌ Unified Tailscale + public access (HIGH value)
- ❌ Tailnet authentication bypass (MEDIUM value)
- ❌ Full auth control with Authelia (MEDIUM value)
- ❌ Declarative service discovery (MEDIUM value)
- ❌ Vendor independence (HIGH value)
- ❌ Privacy/data control (MEDIUM value)

**Net Value:** NEGATIVE - more losses than gains

## Recommendation

### **DO NOT MIGRATE** to Cloudflare Tunnel

After comprehensive analysis, migrating from the current Caddy + tsnsrv + Authelia stack to cloudflared is **not recommended** for this infrastructure.

### Reasoning

1. **No Compelling Business Case**
   - Current solution works reliably
   - Migration solves no existing problems
   - Introduces new complexity without clear benefits

2. **Architectural Regression**
   - Loses elegant unified access model (Tailscale + public)
   - Complicates authentication architecture
   - Reduces declarative configuration capabilities

3. **Strategic Concerns**
   - Introduces vendor lock-in to Cloudflare
   - Reduces infrastructure independence
   - Conflicts with self-hosting philosophy

4. **Opportunity Cost**
   - 6-7 weeks effort for migration
   - Ongoing increased maintenance burden
   - Better invested in other infrastructure improvements

5. **Risk vs. Reward**
   - High migration risk (auth, routing, service availability)
   - Minimal reward (features already covered)
   - Unfavorable risk/reward ratio

### Alternative Recommendations

If addressing specific concerns:

**Concern: SSL certificate management**
- Current ACME setup is reliable and automatic
- No action needed

**Concern: Public access security**
- Tailscale Funnel already provides edge security
- Authelia provides robust authentication
- Consider: Additional rate limiting via Caddy if needed

**Concern: DDoS protection**
- Tailscale Funnel includes DDoS mitigation
- Personal use case has low DDoS risk
- If needed: Add Cloudflare proxy in front (DNS only, not Tunnel)

**Concern: Infrastructure simplification**
- Current stack is already well-integrated
- Migration would increase complexity, not reduce it
- Focus on documentation instead

### When to Revisit This Decision

Consider cloudflared migration only if:

1. **Tailscale Funnel discontinued or becomes expensive**
   - Current alternative becomes unavailable
   - Forces architectural change

2. **Team grows beyond 50 users**
   - Cloudflare Free tier no longer sufficient
   - But also need to reevaluate Authelia scaling

3. **Need true global CDN for public content**
   - Service model changes to public/commercial
   - Content delivery becomes priority

4. **Authelia development stalls**
   - Upstream project abandoned
   - Security vulnerabilities unpatched

5. **Significant improvement in cloudflared NixOS integration**
   - Better abstractions similar to current gateway module
   - Tight Tailscale integration added

None of these conditions currently exist.

## Acceptance Criteria Completion

- [x] #1 Document current gateway.nix architecture and all features it provides
  - Completed in "Current Architecture" section
  - All components, features, and configuration patterns documented

- [x] #2 Research cloudflared capabilities and NixOS integration options
  - Completed via web research and documentation review
  - NixOS module capabilities documented

- [x] #3 Create feature comparison matrix between current solution and cloudflared
  - Comprehensive 15+ feature comparison table created
  - Complexity assessment for each feature included

- [x] #4 Identify blockers or missing features that would prevent migration
  - Three critical blockers identified:
    1. Tailscale integration complexity
    2. Authentication architecture compromise
    3. Loss of declarative configuration abstraction

- [x] #5 Document authentication strategy (Authelia + Cloudflare or migrate to Cloudflare Access)
  - Three options documented with pros/cons/effort
  - Option 3 (Keep Authelia) recommended if migrating

- [x] #6 Outline configuration approach for cloudflared in NixOS
  - Module structure proposed
  - Example configuration provided
  - Secrets management approach documented

- [x] #7 Create migration plan with rollback strategy
  - 7-week phased migration plan created
  - Rollback procedures for each phase
  - Emergency rollback documented

- [x] #8 Document trade-offs and provide recommendation
  - Comprehensive trade-off analysis completed
  - Cost-benefit analysis provided
  - **Recommendation: DO NOT MIGRATE**

## Conclusion

The current Caddy + tsnsrv + Authelia gateway architecture is well-suited for this infrastructure's needs. It provides unified access control, declarative configuration, full self-hosting control, and excellent Tailscale integration.

Cloudflare Tunnel, while a mature and capable product, does not offer sufficient advantages to justify the migration effort, increased complexity, and loss of key features (especially unified Tailscale+public access and vendor independence).

**Final Recommendation:** Maintain current architecture and invest effort in other infrastructure improvements that provide clearer value.

---

**Document Version:** 1.0
**Last Updated:** 2025-10-15
**Next Review:** Only if conditions listed in "When to Revisit This Decision" occur
