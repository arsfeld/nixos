# Architecture Simplification Plan
**Task**: task-122
**Status**: Planning Phase
**Date**: 2025-11-01

## Executive Summary

This document proposes simplifying the current cloud/storage architecture by eliminating the cloud host entirely and routing all traffic through Cloudflare Tunnel directly to storage. This eliminates hidden complexity, reduces operational burden, and makes storage's role as the authoritative service host explicit.

**Recommended Approach**: Cloudflare Tunnel → Storage (decommission cloud entirely)

---

## 1. CURRENT ARCHITECTURE ANALYSIS

### Pain Points and Complexity

#### 1.1 Hidden Duplication - Storage Already Runs Caddy
**The Core Problem**: Both cloud and storage run **identical** Caddy configurations with the same virtual hosts, but this duplication is hidden by DNS routing tricks.

**How It Works Today**:
- **External clients** (public internet):
  - DNS: `*.arsfeld.one` → Cloudflare → Cloud public IP
  - Traffic: User → Cloudflare → Cloud Caddy → Storage Caddy → Service
  - Cloud Caddy acts as reverse proxy to storage

- **Internal clients** (on Tailscale):
  - DNS: Router's Blocky overrides `*.arsfeld.one` → `100.118.254.136` (storage Tailscale IP)
  - Traffic: User → Storage Caddy → Service
  - Cloud is bypassed entirely

**Why This Is Problematic**:
- Not obvious from code that storage runs full Caddy with all services
- Maintenance burden: Changes must be deployed to both hosts
- Confusing: External and internal paths are completely different
- Storage is already the authoritative service host, but architecture hides this
- Cloud's role as "gateway" is misleading - it's just a redundant proxy

#### 1.2 Service Definition Fragmentation
Services defined in **two different patterns**:

**Pattern A**: `modules/constellation/services.nix` (Native systemd services)
- Used for: attic, duplicati, gitea, authelia, dex, mosquitto, owntracks, vault, yarr
- Configuration: Host assignment (`cloud = {...}`, `storage = {...}`)
- Port mapping: Explicit port numbers or `null` for defaults

**Pattern B**: `modules/constellation/media.nix` (Containerized services)
- Used for: Plex, Jellyfin, Sonarr, Radarr, Prowlarr, Overseerr, etc.
- Configuration: Separate `storageServices` and `cloudServices` sections
- Container-specific: Image, volumes, environment variables

**Problems**:
- No unified way to add a service
- Unclear which pattern to use for new services
- Different configuration schemas
- Hard to migrate services between patterns

#### 1.3 Split-Horizon DNS Complexity
**Current DNS Configuration**:
- **External** (Cloudflare): `*.arsfeld.one` → Cloud public IP
- **Internal** (Blocky on router):
  ```nix
  "arsfeld.one" = "100.118.254.136";  # Storage Tailscale IP
  "*.arsfeld.one" = "100.118.254.136";
  ```

**Issues**:
- DNS resolution depends on network location
- Not declarative - requires understanding of both Cloudflare and Blocky
- Debugging is confusing (different paths for internal vs external)
- Can't easily test "external" behavior from internal network

#### 1.4 Current Cloud Host Services
Services that MUST be migrated from cloud to storage:
- **Authentication stack**: authelia, dex, lldap (critical infrastructure)
- **Communication**: mosquitto (MQTT broker), owntracks, thelounge (IRC)
- **Utilities**: vault (secrets), yarr (RSS), whoogle (search), metube (YouTube downloader)
- **Development**: Various dev tools
- **Infrastructure**: tsnsrv (Tailscale node management)

---

## 2. PROPOSED ARCHITECTURE OPTIONS

### Option A: Cloudflare Tunnel → Storage (RECOMMENDED)

#### Architecture
```
Internet Users → Cloudflare (DNS + CDN + WAF) → Cloudflare Tunnel → Storage Tailscale → Caddy → Services

Internal Users → Tailscale → Storage Caddy → Services
```

#### How It Works
1. **Cloudflare Tunnel** (`cloudflared`) runs on storage host
2. Establishes persistent outbound connections to Cloudflare edge
3. Cloudflare routes `*.arsfeld.one` through tunnel to storage
4. No inbound ports needed on storage (outbound-only)
5. Single Caddy instance on storage serves all requests
6. Cloud host can be **decommissioned entirely**

#### Advantages
- ✅ **Simplest**: No cloud host needed at all
- ✅ **Most secure**: No inbound firewall rules, outbound-only connections
- ✅ **NAT-friendly**: Works behind CGNAT, dynamic IPs, etc.
- ✅ **Unified path**: External and internal both hit storage Caddy
- ✅ **Cloudflare features**: DDoS protection, WAF, caching all work
- ✅ **Explicit**: Storage is clearly the authoritative service host
- ✅ **Zero split-horizon**: All DNS points to Cloudflare, tunnel handles routing

#### Disadvantages
- ⚠️ Dependency on Cloudflare Tunnel service
- ⚠️ Slight latency overhead (user → Cloudflare → storage vs direct)
- ⚠️ Requires Cloudflare account with Tunnel support (free tier available)

#### Implementation Requirements
- Deploy `cloudflared` on storage host
- Configure tunnel in Cloudflare dashboard
- Point `*.arsfeld.one` DNS to tunnel
- Remove split-horizon DNS from router
- Decommission cloud host

---

### Option B: Cloudflare DNS → Storage Public IP

#### Architecture
```
Internet Users → Cloudflare (DNS) → Storage Public IP → Caddy → Services
Internal Users → Tailscale → Storage Caddy → Services
```

#### How It Works
1. Storage host has public IP (or port forwarding from router)
2. Cloudflare DNS points `*.arsfeld.one` → Storage public IP
3. Storage firewall allows 80/443 from internet
4. Caddy on storage handles all traffic
5. Cloud host can be **decommissioned entirely**

#### Advantages
- ✅ **Direct routing**: No proxy hops, lowest latency
- ✅ **Simple**: Just DNS change, no tunnel software
- ✅ **No dependencies**: Works without Cloudflare features

#### Disadvantages
- ⚠️ **Requires public IP**: Storage must be publicly reachable
- ⚠️ **Firewall exposure**: Inbound 80/443 from internet
- ⚠️ **No CGNAT support**: Won't work behind carrier-grade NAT
- ⚠️ **Loses Cloudflare features**: No WAF, DDoS protection (unless proxy mode)
- ⚠️ **Single point of failure**: If storage down, everything down

#### Implementation Requirements
- Ensure storage has public IP or configure router port forwarding
- Update Cloudflare DNS A/AAAA records → storage public IP
- Configure storage firewall to allow 80/443
- Remove split-horizon DNS from router
- Decommission cloud host

---

### Option C: Cloud as Minimal L4 Proxy (NOT RECOMMENDED)

#### Architecture
```
Internet Users → Cloudflare → Cloud (HAProxy/iptables) → Storage Caddy → Services
Internal Users → Tailscale → Storage Caddy → Services
```

#### How It Works
1. Cloud runs minimal L4 TCP proxy (HAProxy stream mode or iptables DNAT)
2. Blindly forwards port 443 → storage:443
3. No Caddy on cloud, no service awareness
4. Storage handles all TLS termination and routing
5. Cloud is "dumb pipe"

#### Advantages
- ✅ Keeps cloud in path (if politically required)
- ✅ Simpler than current dual-Caddy setup

#### Disadvantages
- ⚠️ **Still complex**: Maintains two hosts
- ⚠️ **Operational burden**: Cloud still needs maintenance, updates, monitoring
- ⚠️ **Cost**: Cloud VPS still needed (monthly expense)
- ⚠️ **Extra hop**: Adds latency vs direct routing
- ⚠️ **Split-horizon remains**: Internal still bypasses cloud
- ❌ **Doesn't simplify**: Solves duplication but not architecture complexity

#### Implementation Requirements
- Deploy HAProxy or iptables DNAT on cloud
- Remove Caddy from cloud
- Keep cloud host running (ongoing cost)

---

### RECOMMENDATION: Option A (Cloudflare Tunnel)

**Rationale**:
- Eliminates cloud host entirely (cost savings, less maintenance)
- Most secure (outbound-only connections, no firewall holes)
- Works in any network configuration (CGNAT, dynamic IP, etc.)
- Preserves Cloudflare WAF/DDoS protection
- Simplest possible architecture: One host, one Caddy, one path
- Makes storage's role as authoritative host **explicit and obvious**

---

## 3. SERVICE CONSOLIDATION STRATEGY

### Goal
Unify `constellation/services.nix` and `constellation/media.nix` into single service definition pattern.

### Current Patterns Analysis

#### Pattern A (services.nix): Native Services
```nix
services = {
  cloud = { auth = null; dex = null; mqtt = 1883; };
  storage = { attic = 8080; jellyfin = 8096; };
};
```
- Clean host assignment
- Simple port mapping
- Good for systemd services

#### Pattern B (media.nix): Container Services
```nix
storageServices = {
  plex = {
    listenPort = 32400;
    mediaVolumes = true;
    devices = ["/dev/dri:/dev/dri"];
    environment = { ... };
  };
};
```
- Rich container configuration
- Volume mounts, env vars, devices
- Harder to read at a glance

### Proposed Unified Pattern

#### Option 1: Extend services.nix to support containers
```nix
services = {
  storage = {
    # Native service
    attic = { port = 8080; };

    # Container service
    plex = {
      port = 32400;
      container = {
        image = "plexinc/pms-docker";
        volumes = [ "/media:/media" ];
        devices = [ "/dev/dri" ];
      };
    };
  };
};
```

**Advantages**:
- Single location for all services
- Easy to see all services at a glance
- Clear host assignment

**Disadvantages**:
- Mixes concerns (native vs container config)
- Container services have more verbose config

#### Option 2: Keep separation, improve clarity
```nix
# constellation/services.nix - Native systemd services
services.native = {
  storage = { attic = 8080; gitea = 3001; };
  cloud = { };  # Empty after migration
};

# constellation/media.nix - Container services
services.containers = {
  storage = { plex = { ... }; jellyfin = { ... }; };
  cloud = { };  # Empty after migration
};

# Both feed into media.gateway.services
```

**Advantages**:
- Clear separation of concerns
- Container config stays detailed where needed
- Easy migration path (just move services between hosts)

**Disadvantages**:
- Still two files to check

### Recommended Approach: **Option 2 with Improvements**

#### Changes:
1. **Rename for clarity**:
   - `constellation/services.nix` → `constellation/native-services.nix`
   - `constellation/media.nix` → `constellation/container-services.nix`

2. **Eliminate host sections after migration**:
   - Remove `cloud = {}` sections entirely
   - Only `storage = {}` remains
   - Makes it obvious everything runs on storage

3. **Unified service registration**:
   Both files populate `media.gateway.services` with same schema

4. **Documentation**:
   - Add comments explaining when to use each file
   - Native: For systemd services (databases, system daemons)
   - Container: For application services (media, web apps)

---

## 4. CERTIFICATE MANAGEMENT

### Current State
Per user confirmation: **ACME already runs on both cloud and storage - no migration needed**

### Proposed State (Option A: Cloudflare Tunnel)
- ACME continues running on storage
- Cloudflare Tunnel uses Cloudflare-managed certificates (edge termination)
- Storage Caddy uses Let's Encrypt certificates (origin termination)
- **No changes needed** - existing ACME config works as-is

### Certificate Flow
```
User → Cloudflare (Cloudflare cert) → Tunnel → Storage Caddy (Let's Encrypt cert) → Service
```

### Notes
- Cloudflare Tunnel supports origin certificates for end-to-end encryption
- Storage can continue using ACME DNS challenge or HTTP challenge
- No certificate distribution needed between hosts

---

## 5. MIGRATION PLAN FOR CLOUD SERVICES

### Services to Migrate

#### Critical Infrastructure (Phase 1)
- **authelia** (authentication gateway) - modules/constellation/authentication.nix
- **dex** (OIDC provider) - hosts/cloud/services/auth.nix
- **lldap** (LDAP directory) - hosts/cloud/services/auth.nix

#### Communication Services (Phase 2)
- **mosquitto** (MQTT broker) - hosts/cloud/services/mosquitto.nix
- **owntracks** (location tracking) - hosts/cloud/services/owntracks.nix
- **thelounge** (IRC client) - constellation/media.nix cloudServices

#### Utility Services (Phase 3)
- **vault** (secrets manager) - hosts/cloud/services/vault.nix
- **yarr** (RSS reader) - hosts/cloud/services/yarr.nix
- **whoogle** (search proxy) - hosts/cloud/containers.nix
- **metube** (YouTube downloader) - hosts/cloud/containers.nix

### Migration Steps (Per Service)

#### For Native Services (authelia, dex, mosquitto, etc.)
1. **Preparation**:
   - Review service dependencies (databases, secrets, volumes)
   - Identify secrets that need migration (ragenix → sops-nix or stay ragenix)
   - Check disk space on storage for new data

2. **Configuration**:
   - Move service definition from `hosts/cloud/services/*.nix` to `hosts/storage/services/*.nix`
   - Update `constellation/services.nix`: Move service from `cloud = {}` to `storage = {}`
   - Update any hardcoded hostnames (cloud.bat-boa.ts.net → storage.bat-boa.ts.net)

3. **Secrets**:
   - If service uses ragenix: Add storage to secrets.nix recipients
   - If service uses sops-nix: Add storage host key to .sops.yaml
   - Rekey secrets with storage access

4. **Data Migration**:
   - Stop service on cloud: `systemctl stop service-name`
   - Rsync data: `rsync -avz /var/lib/service-name/ storage:/var/lib/service-name/`
   - Verify data integrity

5. **Deployment**:
   - Deploy to storage: `just deploy storage`
   - Verify service starts: `systemctl status service-name`
   - Check logs: `journalctl -u service-name -f`

6. **Testing**:
   - Test internal access: `https://service.bat-boa.ts.net`
   - Test external access: `https://service.arsfeld.one`
   - Verify authentication flow (if applicable)

7. **Cleanup**:
   - Stop service on cloud permanently
   - Remove service definition from cloud config
   - Deploy cloud to remove service: `just deploy cloud`

#### For Container Services (thelounge, whoogle, metube)
1. **Configuration**:
   - Move service from `cloudServices` to `storageServices` in `constellation/media.nix`
   - Update host attribution (automatically handled by `addHost` function)

2. **Data Migration**:
   - Stop container on cloud: `systemctl stop podman-container-name`
   - Rsync volumes: `rsync -avz /var/lib/container-name/ storage:/var/lib/container-name/`

3. **Deployment & Testing**:
   - Same as native services above

### Migration Order (Phased Approach)

#### Phase 1: Non-Critical Utilities (Lowest Risk)
- whoogle, metube, yarr
- **Why first**: Low usage, easy rollback, no dependencies

#### Phase 2: Communication Services
- mosquitto, owntracks, thelounge
- **Why second**: Some dependencies but isolated

#### Phase 3: Authentication Stack (Highest Risk)
- dex, lldap, authelia (in this order)
- **Why last**: Critical infrastructure, affects all services
- **Special care**: Requires testing all downstream services

### Data Persistence Verification
Before each migration:
```bash
# On cloud
du -sh /var/lib/service-name
md5sum /var/lib/service-name/critical-file

# After rsync to storage
du -sh /var/lib/service-name
md5sum /var/lib/service-name/critical-file  # Must match
```

---

## 6. DNS AND ROUTING CHANGES

### Current DNS Configuration

#### External (Cloudflare)
```
*.arsfeld.one A <cloud-public-ip>
```

#### Internal (Router Blocky)
```nix
customDNS.mapping = {
  "arsfeld.one" = "100.118.254.136";      # Storage Tailscale IP
  "*.arsfeld.one" = "100.118.254.136";
};
```

### Proposed DNS Configuration (Option A: Cloudflare Tunnel)

#### External (Cloudflare)
```
# Cloudflare Dashboard:
# 1. Create Cloudflare Tunnel pointing to storage
# 2. Configure tunnel route: *.arsfeld.one → tunnel
# DNS automatically managed by Cloudflare
```

#### Internal (Router Blocky)
```nix
# REMOVE split-horizon DNS - no longer needed
# Blocky will use Cloudflare for arsfeld.one like any other domain
# Tailscale access via *.bat-boa.ts.net remains unchanged
```

### Routing Changes

#### Before (Split-Horizon)
```
External: User → Cloudflare → Cloud (proxy) → Storage → Service
Internal: User → Storage (direct via DNS override) → Service
```

#### After (Unified via Tunnel)
```
External: User → Cloudflare → Tunnel → Storage → Service
Internal: User → Tailscale → Storage → Service (via *.bat-boa.ts.net)
         OR
         User → Cloudflare → Tunnel → Storage → Service (via *.arsfeld.one)
```

### Implementation Steps

1. **Deploy Cloudflare Tunnel**:
   ```nix
   # hosts/storage/services/cloudflared.nix
   services.cloudflared = {
     enable = true;
     tunnels = {
       "<tunnel-id>" = {
         credentialsFile = config.sops.secrets.cloudflare-tunnel-creds.path;
         default = "http://localhost:443";  # Route to local Caddy
       };
     };
   };
   ```

2. **Configure Cloudflare Dashboard**:
   - Create tunnel
   - Add route: `*.arsfeld.one` → tunnel
   - Verify DNS updates

3. **Remove Split-Horizon DNS**:
   ```nix
   # hosts/router/services/dns.nix
   # DELETE these lines:
   # "arsfeld.one" = "100.118.254.136";
   # "*.arsfeld.one" = "100.118.254.136";
   ```

4. **Deploy Changes**:
   ```bash
   just deploy storage  # Enable tunnel
   just deploy router   # Remove DNS override
   ```

5. **Verification**:
   - External: `curl https://jellyfin.arsfeld.one` (should work)
   - Internal: `curl https://jellyfin.bat-boa.ts.net` (should work)
   - Check tunnel status: `cloudflared tunnel info <tunnel-id>`

---

## 7. SECURITY CONSIDERATIONS

### External Access Security

#### Current Security Layers
1. Cloudflare WAF and DDoS protection
2. Cloud host firewall (limited to 80/443/22)
3. Caddy reverse proxy on cloud
4. Authelia authentication (for most services)
5. Tailscale ACLs (for internal access)

#### Proposed Security Layers (Option A: Cloudflare Tunnel)
1. **Cloudflare WAF and DDoS protection** ✓ (preserved)
2. **Cloudflare Tunnel authentication** ✓ (new layer - tunnel credentials required)
3. **No inbound firewall rules** ✓ (improved - outbound-only is more secure)
4. **Storage host firewall** ✓ (existing - tailscale, local services only)
5. **Caddy reverse proxy on storage** ✓ (existing)
6. **Authelia authentication** ✓ (preserved after migration)
7. **Tailscale ACLs** ✓ (preserved)

#### Security Improvements
- ✅ **Reduced attack surface**: No public 80/443 ports on storage
- ✅ **Tunnel authentication**: Cloudflare verifies tunnel credentials
- ✅ **Outbound-only**: Storage initiates all connections (NAT-friendly, CGNAT-proof)
- ✅ **Zero-trust**: Cloudflare enforces access policies before reaching tunnel

#### Security Risks and Mitigations

**Risk 1: Cloudflare Tunnel Compromise**
- *Impact*: Attacker with tunnel credentials could route traffic
- *Mitigation*:
  - Store credentials in sops-nix encrypted secrets
  - Rotate tunnel credentials periodically
  - Monitor tunnel usage in Cloudflare dashboard
  - Enable Cloudflare Access policies (optional additional layer)

**Risk 2: Single Point of Failure (Storage Host)**
- *Impact*: If storage compromised, all services exposed
- *Mitigation*:
  - Keep storage host hardened (minimal packages, regular updates)
  - Fail2ban for brute force protection
  - Authelia rate limiting
  - Tailscale ACLs restrict SSH access
  - Regular security audits

**Risk 3: Loss of Cloud as DMZ**
- *Impact*: Cloud host previously acted as buffer between internet and storage
- *Mitigation*:
  - Cloudflare Tunnel provides similar isolation
  - Storage never accepts direct inbound connections
  - Authelia still enforces authentication
  - Service-level authentication still required (bypassAuth = false)

### Authentication Flow Changes

#### Current Flow (External)
```
User → Cloudflare → Cloud Caddy → Authelia (cloud) → Cloud Caddy → Storage Caddy → Service
```

#### Current Flow (Internal)
```
User → Storage Caddy → Authelia (cloud via TS) → Storage Caddy → Service
```

#### Proposed Flow (External via Tunnel)
```
User → Cloudflare → Tunnel → Storage Caddy → Authelia (storage) → Storage Caddy → Service
```

#### Proposed Flow (Internal via Tailscale)
```
User → Storage Caddy → Authelia (storage) → Storage Caddy → Service
```

**Changes Required**:
- Migrate Authelia from cloud to storage (already in Phase 3 migration)
- Update Authelia configuration to reference storage hostname
- Update Caddy forward_auth to point to localhost (Authelia on same host)

---

## 8. ROLLBACK STRATEGY

### Rollback Triggers
- Critical service unavailable >15 minutes
- Authentication completely broken
- Data loss detected
- Performance degradation >50%
- User-reported widespread issues

### Rollback Procedure

#### Level 1: Single Service Rollback
If a migrated service fails:

```bash
# 1. Stop service on storage
systemctl stop service-name

# 2. Revert configuration
git revert <commit-hash>
just deploy storage

# 3. Restart service on cloud
just deploy cloud
systemctl start service-name

# 4. Verify
curl https://service.arsfeld.one
```

**Time to rollback**: ~5-10 minutes

#### Level 2: DNS Rollback (Cloudflare Tunnel Issues)
If tunnel fails or performs poorly:

```bash
# 1. In Cloudflare Dashboard:
#    - Disable tunnel route for *.arsfeld.one
#    - Update DNS: *.arsfeld.one → cloud public IP

# 2. Restore split-horizon DNS on router
git revert <commit-hash>  # Restore DNS overrides
just deploy router

# 3. Ensure cloud Caddy is running
just deploy cloud
systemctl start caddy
```

**Time to rollback**: ~10-15 minutes (DNS propagation)

#### Level 3: Full Architecture Rollback
If entire migration needs reversal:

```bash
# 1. Restore all cloud services
git revert <start-commit>..<end-commit>
just deploy cloud
just deploy storage
just deploy router

# 2. Verify all services on cloud
for service in authelia dex mosquitto owntracks vault yarr whoogle metube thelounge; do
  systemctl status $service
done

# 3. Restore Cloudflare DNS (if changed)
# Update DNS to cloud public IP

# 4. Verify external access
curl https://auth.arsfeld.one
```

**Time to rollback**: ~30-60 minutes

### Rollback Safeguards

#### Before Starting Migration
1. **Git tag**: `git tag pre-architecture-migration`
2. **Backup cloud data**: Full rsync of /var/lib to external storage
3. **Backup storage data**: Snapshot of critical service directories
4. **Document current state**:
   - List of all running services
   - Current DNS configuration
   - Current Cloudflare settings

#### During Migration (Per Phase)
1. **Git commit per service**: Each service migration is separate commit
2. **Test before proceeding**: Each service must work before next migration
3. **Keep cloud running**: Don't decommission cloud until ALL services migrated and tested
4. **Monitoring**: Watch Netdata, logs for errors

#### Rollback Testing
Before production migration:
1. Test rollback procedure in staging (if available)
2. Document rollback time for each level
3. Ensure backups are restorable

---

## 9. TESTING STRATEGY

### Pre-Migration Testing

#### Cloudflare Tunnel PoC
1. Deploy tunnel on storage (non-production subdomain)
2. Test single service (e.g., `test.arsfeld.one` → Jellyfin)
3. Measure latency vs direct routing
4. Verify HTTPS, WebSocket support
5. Load test (simulate 10 concurrent users)

#### Service Migration Dry Run
1. Migrate low-risk service (whoogle) to storage
2. Test external and internal access
3. Verify authentication flow
4. Practice rollback procedure
5. Document any issues

### During Migration Testing (Per Service)

#### Functional Tests
- [ ] Service starts successfully (`systemctl status`)
- [ ] Service logs show no errors (`journalctl -u`)
- [ ] Service responds to health check endpoint
- [ ] Service-specific functionality works (e.g., search for whoogle)

#### Access Tests
- [ ] Internal Tailscale access: `https://service.bat-boa.ts.net`
- [ ] External access: `https://service.arsfeld.one`
- [ ] Authentication required (if bypassAuth = false)
- [ ] Authentication bypass works (if bypassAuth = true)

#### Integration Tests
- [ ] Service dependencies accessible (databases, APIs, etc.)
- [ ] Inter-service communication works (e.g., Sonarr → Prowlarr)
- [ ] Webhooks and notifications deliver
- [ ] Scheduled tasks execute

### Post-Migration Testing

#### End-to-End Tests
- [ ] User login via Authelia
- [ ] Access protected service
- [ ] Upload/download files
- [ ] WebSocket connections (e.g., Jellyfin streaming)
- [ ] API access (for automation)

#### Performance Tests
- [ ] Page load time <2s (vs baseline)
- [ ] Video streaming starts <5s
- [ ] API response time <500ms
- [ ] No dropped connections under load

#### Security Tests
- [ ] Unauthenticated access blocked
- [ ] SSL certificate valid
- [ ] No mixed content warnings
- [ ] Security headers present
- [ ] Fail2ban triggers on brute force

---

## 10. IMPLEMENTATION PHASES

### Phase 0: Preparation (Week 1)
- [ ] Deploy Cloudflare Tunnel PoC on storage (test subdomain)
- [ ] Test tunnel with one service
- [ ] Create rollback documentation
- [ ] Backup cloud and storage data
- [ ] Git tag: `pre-architecture-migration`

### Phase 1: Utility Services (Week 2)
- [ ] Migrate whoogle → storage
- [ ] Migrate metube → storage
- [ ] Migrate yarr → storage
- [ ] Test and verify each service
- [ ] Document any issues

### Phase 2: Communication Services (Week 3)
- [ ] Migrate mosquitto → storage
- [ ] Migrate owntracks → storage
- [ ] Migrate thelounge → storage
- [ ] Test MQTT clients, location tracking, IRC
- [ ] Verify integrations

### Phase 3: Authentication Stack (Week 4)
- [ ] Migrate lldap → storage
- [ ] Migrate dex → storage
- [ ] Migrate authelia → storage
- [ ] Test authentication for ALL services
- [ ] Verify OIDC flows

### Phase 4: DNS Cutover (Week 5)
- [ ] Configure Cloudflare Tunnel routes for *.arsfeld.one
- [ ] Remove split-horizon DNS from router
- [ ] Test external access via tunnel
- [ ] Monitor for 48 hours
- [ ] Verify no issues

### Phase 5: Decommission Cloud (Week 6)
- [ ] Final backup of cloud data
- [ ] Stop all cloud services
- [ ] Update monitoring to remove cloud
- [ ] Document cloud host shutdown
- [ ] Celebrate! 🎉

### Success Criteria
- ✅ All services accessible externally via `*.arsfeld.one`
- ✅ All services accessible internally via `*.bat-boa.ts.net`
- ✅ Authentication working for all protected services
- ✅ No performance degradation vs baseline
- ✅ Cloud host decommissioned
- ✅ Single Caddy configuration on storage
- ✅ No split-horizon DNS
- ✅ Documentation updated

### Cost Savings
- **Monthly VPS cost for cloud host**: Eliminated
- **Maintenance time**: Reduced by 50% (one host vs two)
- **Complexity**: Drastically reduced

---

## FINAL RECOMMENDATION

**Recommended Architecture**: Option A - Cloudflare Tunnel

### Why This Option?
1. **Simplest possible architecture**:
   - One host (storage)
   - One web server (Caddy on storage)
   - One DNS path (via Cloudflare Tunnel)

2. **Most secure**:
   - No inbound firewall rules
   - Outbound-only connections
   - Cloudflare WAF/DDoS protection maintained

3. **Lowest operational burden**:
   - Decommission cloud host (save VPS costs)
   - Single host to maintain and monitor
   - No split-horizon DNS complexity

4. **Best for homelabs**:
   - Works behind CGNAT
   - Works with dynamic IPs
   - No port forwarding needed

5. **Makes architecture explicit**:
   - Storage is obviously the service host
   - No hidden routing behaviors
   - Clear, understandable traffic flow

---

## NEXT STEPS

**Awaiting user approval of this plan before proceeding with implementation.**

### Questions for User:
1. Does Option A (Cloudflare Tunnel) align with your goals?
2. Is the 6-week phased migration timeline acceptable?
3. Any concerns about decommissioning cloud host entirely?
4. Should we proceed with Phase 0 PoC after approval?
