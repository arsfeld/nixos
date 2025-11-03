# Dual Cloudflare Tunnel Architecture Plan (Task-123)

**Alternative Architecture**: Keep both hosts operational with separate domains via dual Cloudflare Tunnels

**Date**: 2025-10-31
**Status**: Planning Phase
**Related**: task-122 (single-tunnel alternative), task-120 (sops-nix migration)

---

## Executive Summary

This plan proposes a **dual Cloudflare Tunnel architecture** as an alternative to task-122's recommendation to decommission the cloud host entirely. Instead of consolidating everything onto the storage host, this approach:

- **Keeps both hosts operational** with separate domains
- **Storage host** serves `*.arsfeld.one` via Cloudflare Tunnel (media/storage services)
- **Cloud host** serves `*.rosenfeld.one` via Cloudflare Tunnel (auth/utility services)
- **Eliminates split-horizon DNS complexity** while maintaining service distribution
- **No service migration required** - simpler deployment than task-122

### Comparison to Task-122

| Aspect | Task-122 (Single Tunnel) | Task-123 (Dual Tunnel) |
|--------|-------------------------|------------------------|
| **Final State** | Storage only, cloud decommissioned | Both hosts operational |
| **Domains** | `*.arsfeld.one` only | `*.arsfeld.one` + `*.rosenfeld.one` |
| **Service Migration** | Required (6+ services) | Not required |
| **Operational Cost** | Lower (1 VPS) | Higher (2 VPS) |
| **Complexity** | Lower (1 host, 1 tunnel) | Higher (2 hosts, 2 tunnels) |
| **Implementation Time** | 6 weeks (phased migration) | 2-3 weeks (tunnel deployment only) |
| **Rollback Difficulty** | Moderate (services moved) | Easy (just DNS changes) |
| **Future Consolidation** | N/A (already consolidated) | Can migrate to single-tunnel later |

**Recommendation**: This dual-tunnel approach is **lower risk** and **faster to implement**, but task-122's single-tunnel approach is **operationally superior** long-term.

---

## Current Architecture Pain Points

*(Same analysis as task-122 - see that document for full details)*

1. **Hidden Caddy Duplication**: Both cloud and storage run identical Caddy configs
2. **Split-Horizon DNS Confusion**: External and internal traffic follow completely different paths
3. **Implicit Service Distribution**: Not clear from config which host is authoritative
4. **Cloud as Redundant Proxy**: Adds latency and complexity without clear benefit

**Root Issue**: The split-horizon DNS masks that storage is already self-sufficient. Cloud is a pass-through proxy that external clients use but internal clients bypass.

---

## Proposed Dual Tunnel Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────┐
│                         Internet                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴──────────┐
                    │                     │
            ┌───────▼──────┐      ┌──────▼───────┐
            │  Cloudflare  │      │  Cloudflare  │
            │  (*.arsfeld  │      │  (*.rosenfeld│
            │   .one DNS)  │      │   .one DNS)  │
            └───────┬──────┘      └──────┬───────┘
                    │                     │
            ┌───────▼──────┐      ┌──────▼───────┐
            │  CF Tunnel 1 │      │  CF Tunnel 2 │
            │  (Outbound)  │      │  (Outbound)  │
            └───────┬──────┘      └──────┬───────┘
                    │                     │
         ┌──────────▼──────────┐  ┌──────▼──────────┐
         │   Storage Host      │  │   Cloud Host    │
         │   (100.118.254.137) │  │   (100.118.254  │
         │                     │  │    .136)        │
         │   Caddy (80/443)    │  │   Caddy (80/443)│
         │   ├─ Jellyfin       │  │   ├─ Authelia   │
         │   ├─ Plex           │  │   ├─ LLDAP      │
         │   ├─ Overseerr      │  │   ├─ Mosquitto  │
         │   ├─ Sonarr/Radarr  │  │   ├─ OwnTracks  │
         │   ├─ Gitea          │  │   ├─ Vault      │
         │   ├─ Nextcloud      │  │   ├─ Yarr       │
         │   └─ 60+ more       │  │   └─ 8 more     │
         └─────────────────────┘  └─────────────────┘
                    │                     │
         ┌──────────▼─────────────────────▼──────┐
         │          Tailscale VPN                 │
         │          (bat-boa.ts.net)              │
         │  - Internal access (unified network)   │
         │  - Service-to-service communication    │
         └────────────────────────────────────────┘
```

### Key Architectural Principles

1. **Domain Separation by Function**:
   - `*.arsfeld.one` → Media, storage, and primary services (Storage host)
   - `*.rosenfeld.one` → Authentication, utilities, and infrastructure (Cloud host)

2. **No Split-Horizon DNS**:
   - All DNS (internal and external) points to Cloudflare
   - Cloudflare Tunnel routes to appropriate host
   - Consistent routing regardless of client location

3. **Independent Host Operations**:
   - Each host runs its own Caddy instance
   - Each host manages its own certificates via ACME
   - Each host runs its own Cloudflare Tunnel daemon

4. **Tailscale for Inter-Service Communication**:
   - Authelia on cloud accessible via `cloud.bat-boa.ts.net:9091`
   - Services on storage can authenticate against cloud Authelia
   - Maintains existing service integration

---

## Service Distribution

### Storage Host Services (`*.arsfeld.one`)

**Media Streaming**:
- `jellyfin.arsfeld.one` - Jellyfin media server
- `plex.arsfeld.one` - Plex media server
- `audiobookshelf.arsfeld.one` - Audiobook streaming

**Media Acquisition**:
- `sonarr.arsfeld.one` - TV show management
- `radarr.arsfeld.one` - Movie management
- `prowlarr.arsfeld.one` - Indexer manager
- `bazarr.arsfeld.one` - Subtitle management
- `overseerr.arsfeld.one` - Media request system
- `autobrr.arsfeld.one` - Torrent automation
- `jackett.arsfeld.one` - Indexer proxy

**File Management**:
- `nextcloud.arsfeld.one` - Cloud storage
- `filestash.arsfeld.one` - File browser
- `filebrowser.arsfeld.one` - Alternative file browser
- `syncthing.arsfeld.one` - File synchronization

**Development & Infrastructure**:
- `gitea.arsfeld.one` - Git hosting
- `code.arsfeld.one` - Code Server (VS Code in browser)
- `attic.arsfeld.one` - Nix binary cache
- `n8n.arsfeld.one` - Workflow automation
- `windmill.arsfeld.one` - Workflow engine

**Content Management**:
- `stash.arsfeld.one` - Media organizer
- `kavita.arsfeld.one` - Manga/comics reader
- `komga.arsfeld.one` - Alternative comics reader
- `photoprism.arsfeld.one` - Photo management
- `immich.arsfeld.one` - Photo backup

**Home Automation**:
- `homeassistant.arsfeld.one` - Home automation
- `grocy.arsfeld.one` - Groceries management

**Monitoring**:
- `grafana.arsfeld.one` - Metrics visualization
- `netdata.arsfeld.one` - System monitoring
- `scrutiny.arsfeld.one` - Disk health monitoring

*...and 40+ additional services (see modules/constellation/services.nix and media.nix)*

**Total**: ~70 services on storage

### Cloud Host Services (`*.rosenfeld.one`)

**Authentication & Identity**:
- `auth.rosenfeld.one` - Authelia SSO
- `dex.rosenfeld.one` - OpenID Connect provider
- `lldap.rosenfeld.one` - LDAP directory

**Communication**:
- `mosquitto.rosenfeld.one` - MQTT broker (port 1883/8883)
- `owntracks.rosenfeld.one` - Location tracking
- `thelounge.rosenfeld.one` - IRC web client

**Utilities**:
- `vault.rosenfeld.one` - Secret management
- `yarr.rosenfeld.one` - RSS reader
- `whoogle.rosenfeld.one` - Privacy-focused search
- `metube.rosenfeld.one` - YouTube downloader

**Total**: ~8 services on cloud

### Cross-Domain Dependencies

**Authelia Integration**:
- Storage services needing authentication will still forward_auth to `cloud.bat-boa.ts.net:9091`
- Maintains existing auth flow over Tailscale
- No changes to service configurations needed

**No Other Dependencies**:
- Cloud services are self-contained (auth, MQTT, utilities)
- Storage services are self-contained (media, files, apps)
- Clean separation of concerns

---

## Cloudflare Tunnel Configuration

### Tunnel 1: Storage (`*.arsfeld.one`)

**NixOS Configuration** (`hosts/storage/services/cloudflare-tunnel.nix`):

```nix
{ config, pkgs, ... }:

{
  services.cloudflared = {
    enable = true;
    tunnels = {
      "storage-arsfeld" = {
        credentialsFile = config.sops.secrets."cloudflare/tunnel-storage-creds".path;
        default = "http_status:404";

        ingress = {
          # Media services
          "jellyfin.arsfeld.one" = "http://localhost:8096";
          "plex.arsfeld.one" = "http://localhost:32400";
          "overseerr.arsfeld.one" = "http://localhost:5055";

          # Acquisition services
          "sonarr.arsfeld.one" = "http://localhost:8989";
          "radarr.arsfeld.one" = "http://localhost:7878";
          "prowlarr.arsfeld.one" = "http://localhost:9696";
          "bazarr.arsfeld.one" = "http://localhost:6767";

          # File management
          "nextcloud.arsfeld.one" = "http://localhost:8081";
          "filestash.arsfeld.one" = "http://localhost:8334";

          # Development
          "gitea.arsfeld.one" = "http://localhost:3001";
          "code.arsfeld.one" = "http://localhost:8082";
          "attic.arsfeld.one" = "http://localhost:8095";

          # ... (all other storage services)

          # Catch-all route through Caddy for any service not explicitly listed
          "*.arsfeld.one" = "http://localhost:80";
        };
      };
    };
  };

  # Secret configuration
  sops.secrets."cloudflare/tunnel-storage-creds" = {
    sopsFile = ../../secrets/sops/storage.yaml;
    mode = "0440";
    owner = "cloudflared";
    group = "cloudflared";
  };
}
```

**Cloudflare Dashboard Configuration**:
1. Create tunnel named `storage-arsfeld`
2. Download credentials JSON
3. Add to sops: `sops secrets/sops/storage.yaml` (add cloudflare.tunnel-storage-creds)
4. Configure DNS records:
   - `jellyfin.arsfeld.one` → CNAME → `<tunnel-id>.cfargotunnel.com`
   - `plex.arsfeld.one` → CNAME → `<tunnel-id>.cfargotunnel.com`
   - `*.arsfeld.one` → CNAME → `<tunnel-id>.cfargotunnel.com` (wildcard)

### Tunnel 2: Cloud (`*.rosenfeld.one`)

**NixOS Configuration** (`hosts/cloud/services/cloudflare-tunnel.nix`):

```nix
{ config, pkgs, ... }:

{
  services.cloudflared = {
    enable = true;
    tunnels = {
      "cloud-rosenfeld" = {
        credentialsFile = config.sops.secrets."cloudflare/tunnel-cloud-creds".path;
        default = "http_status:404";

        ingress = {
          # Authentication services
          "auth.rosenfeld.one" = "http://localhost:9091";
          "dex.rosenfeld.one" = "http://localhost:5556";
          "lldap.rosenfeld.one" = "http://localhost:17170";

          # Communication services
          "owntracks.rosenfeld.one" = "http://localhost:8083";
          "thelounge.rosenfeld.one" = "http://localhost:9002";

          # Utility services
          "vault.rosenfeld.one" = "http://localhost:8200";
          "yarr.rosenfeld.one" = "http://localhost:7070";
          "whoogle.rosenfeld.one" = "http://localhost:5000";
          "metube.rosenfeld.one" = "http://localhost:8081";

          # Catch-all
          "*.rosenfeld.one" = "http://localhost:80";
        };
      };
    };
  };

  # Secret configuration (already using sops-nix PoC on cloud)
  sops.secrets."cloudflare/tunnel-cloud-creds" = {
    sopsFile = ../../secrets/sops/cloud-poc.yaml;
    mode = "0440";
    owner = "cloudflared";
    group = "cloudflared";
  };
}
```

**Cloudflare Dashboard Configuration**:
1. Create tunnel named `cloud-rosenfeld`
2. Download credentials JSON
3. Add to existing cloud sops file (already using sops-nix)
4. Configure DNS records:
   - `auth.rosenfeld.one` → CNAME → `<tunnel-id>.cfargotunnel.com`
   - `*.rosenfeld.one` → CNAME → `<tunnel-id>.cfargotunnel.com` (wildcard)

### Special Considerations

**MQTT on Cloud** (non-HTTP service):
```nix
# In cloudflare-tunnel.nix ingress:
"mosquitto.rosenfeld.one" = {
  service = "tcp://localhost:1883";
};
```

Alternatively, MQTT can remain Tailscale-only (not exposed via Cloudflare Tunnel) since it's primarily for internal IoT devices.

**Large File Uploads** (Nextcloud, Immich):
- Cloudflare Tunnel supports up to 100MB files on free plan
- May need to configure `noTLSVerify = true` for self-signed certs during testing
- Consider Cloudflare Tunnel paid plan for larger uploads

---

## DNS Configuration Changes

### Current State (Split-Horizon)

**External Clients**:
- `*.arsfeld.one` → Cloudflare DNS → Cloud public IP → Cloud Caddy → Storage Caddy → Service

**Internal Clients (Tailscale/LAN)**:
- `*.arsfeld.one` → Router Blocky DNS override → Storage Tailscale IP → Storage Caddy → Service

### New State (Unified via Cloudflare Tunnel)

**All Clients (Internal and External)**:
- `*.arsfeld.one` → Cloudflare DNS → CNAME `<tunnel-id>.cfargotunnel.com` → Cloudflare edge → Tunnel to Storage → Storage Caddy → Service
- `*.rosenfeld.one` → Cloudflare DNS → CNAME `<tunnel-id>.cfargotunnel.com` → Cloudflare edge → Tunnel to Cloud → Cloud Caddy → Service

### Required DNS Changes

#### Remove Split-Horizon Configuration

**File**: `hosts/router/services/dns.nix`

```nix
# REMOVE these lines (lines 45-58):
customDNS = {
  mapping = {
    "*.arsfeld.one" = "100.118.254.136";  # DELETE - no longer needed
  };
};
```

After removal, all clients (internal and external) will use Cloudflare DNS → Cloudflare Tunnel routing.

#### Cloudflare DNS Records

**For `arsfeld.one` domain**:
```
Type: CNAME
Name: *
Target: <storage-tunnel-id>.cfargotunnel.com
Proxy: Yes (orange cloud)
```

**For `rosenfeld.one` domain**:
```
Type: CNAME
Name: *
Target: <cloud-tunnel-id>.cfargotunnel.com
Proxy: Yes (orange cloud)
```

**Additional specific records** (if needed for better routing):
- `jellyfin.arsfeld.one` → `<storage-tunnel-id>.cfargotunnel.com`
- `auth.rosenfeld.one` → `<cloud-tunnel-id>.cfargotunnel.com`
- etc.

---

## Certificate Management

### Current State

Both hosts independently manage certificates:
- **Storage**: ACME via Cloudflare DNS provider (Let's Encrypt)
- **Cloud**: ACME via Cloudflare DNS provider (Let's Encrypt)

Both use the same `secrets/cloudflare.age` for DNS challenges.

### New State with Cloudflare Tunnel

**Option 1: Keep ACME on Both Hosts** (Recommended)
- No changes required
- Each Caddy instance still manages its own certificates
- Cloudflare Tunnel passes HTTPS traffic through to Caddy
- Caddy terminates TLS with Let's Encrypt certs

**Option 2: Use Cloudflare-Managed Certificates**
- Cloudflare Tunnel can terminate TLS at the edge
- Backend uses HTTP or Cloudflare origin certificates
- Simpler config but less control
- Storage and Cloud would use HTTP internally

**Recommendation**: **Option 1** - Keep existing ACME setup. It already works and provides end-to-end encryption.

### Configuration (No Changes Needed)

Existing config in `modules/media/config.nix` continues to work:

```nix
acmeEmail = "alex@arsfeld.one";
dnsProvider = "cloudflare";
# credentials from config.sops.secrets.cloudflare.path
```

Both hosts will continue to request certificates independently via DNS-01 challenge.

---

## Implementation Plan

### Phase 0: Preparation (Week 1)

**Tasks**:
1. ✅ Create this architecture plan document
2. ✅ Review and compare with task-122 approach
3. ⬜ Set up Cloudflare Tunnel in Cloudflare dashboard:
   - Create `storage-arsfeld` tunnel
   - Create `cloud-rosenfeld` tunnel
   - Download credentials JSON for both
4. ⬜ Add tunnel credentials to sops-nix:
   - `secrets/sops/storage.yaml` - add `cloudflare.tunnel-storage-creds`
   - `secrets/sops/cloud-poc.yaml` - add `cloudflare.tunnel-cloud-creds`
5. ⬜ Create NixOS modules for Cloudflare Tunnel:
   - `hosts/storage/services/cloudflare-tunnel.nix`
   - `hosts/cloud/services/cloudflare-tunnel.nix`

**Validation**:
- Tunnel credentials encrypted and accessible
- NixOS configuration builds successfully

### Phase 1: Storage Tunnel Deployment (Week 2)

**Tasks**:
1. ⬜ Deploy cloudflared to storage host:
   ```bash
   just deploy storage
   ```
2. ⬜ Verify tunnel is connected in Cloudflare dashboard
3. ⬜ Configure DNS records for `*.arsfeld.one` (do NOT set as active yet):
   - Create CNAME records pointing to tunnel
   - Keep as "DNS only" (gray cloud) initially
4. ⬜ Test tunnel routing with temporary subdomain:
   - Create `test.arsfeld.one` → tunnel CNAME
   - Enable proxy (orange cloud) on test subdomain only
   - Verify service access via `test.arsfeld.one`
5. ⬜ Test internal Tailscale access still works:
   - Verify services accessible via `*.bat-boa.ts.net`
   - Verify Tailscale network not broken

**Validation Checklist**:
- [ ] Storage tunnel shows "Healthy" in Cloudflare dashboard
- [ ] Test subdomain resolves and serves service correctly
- [ ] Authelia authentication works via tunnel
- [ ] Large file upload works (test with Nextcloud/Immich)
- [ ] Tailscale access unaffected

### Phase 2: Cloud Tunnel Deployment (Week 2)

**Tasks**:
1. ⬜ Deploy cloudflared to cloud host:
   ```bash
   just deploy cloud
   ```
2. ⬜ Verify tunnel is connected in Cloudflare dashboard
3. ⬜ Configure DNS records for `*.rosenfeld.one`:
   - Create CNAME records pointing to tunnel
   - Initially keep as "DNS only" (gray cloud)
4. ⬜ Test tunnel routing with temporary subdomain:
   - Create `test.rosenfeld.one` → tunnel CNAME
   - Enable proxy (orange cloud) on test subdomain only
5. ⬜ Test authentication services:
   - Verify Authelia accessible via `auth.rosenfeld.one`
   - Verify LLDAP accessible
   - Test login flow

**Validation Checklist**:
- [ ] Cloud tunnel shows "Healthy" in Cloudflare dashboard
- [ ] Cloud services accessible via `*.rosenfeld.one`
- [ ] Authelia still accessible from storage services (via Tailscale)
- [ ] MQTT accessible (if routed through tunnel)

### Phase 3: DNS Cutover for `*.rosenfeld.one` (Week 3)

**Tasks**:
1. ⬜ Enable Cloudflare proxy for `*.rosenfeld.one`:
   - Change all rosenfeld.one DNS records to "Proxied" (orange cloud)
2. ⬜ Monitor cloud services:
   - Check Authelia login works
   - Verify all cloud services accessible
3. ⬜ Test storage→cloud authentication:
   - Verify storage services can still authenticate against Authelia
   - Check forward_auth over Tailscale still works

**Rollback Plan**:
- Change DNS records back to "DNS only" (gray cloud)
- Services will revert to old routing immediately

**Validation Checklist**:
- [ ] All `*.rosenfeld.one` services accessible
- [ ] No authentication errors from storage services
- [ ] No service disruptions

### Phase 4: DNS Cutover for `*.arsfeld.one` (Week 3)

**Tasks**:
1. ⬜ Remove split-horizon DNS override:
   - Edit `hosts/router/services/dns.nix`
   - Remove `"*.arsfeld.one" = "100.118.254.136";` mapping
   - Deploy router configuration:
     ```bash
     just deploy router
     ```
2. ⬜ Enable Cloudflare proxy for `*.arsfeld.one`:
   - Change all arsfeld.one DNS records to "Proxied" (orange cloud)
3. ⬜ Monitor storage services:
   - Verify all services accessible from external network
   - Verify all services accessible from internal network (now via tunnel)
4. ⬜ Test internal routing performance:
   - Internal clients now route: LAN → Cloudflare → Tunnel → Storage
   - May have slightly higher latency than previous direct routing
   - Acceptable tradeoff for architectural simplicity

**Rollback Plan**:
1. Re-enable split-horizon DNS on router
2. Change DNS records back to "DNS only"
3. Deploy router: `just deploy router`

**Validation Checklist**:
- [ ] All `*.arsfeld.one` services accessible externally
- [ ] All `*.arsfeld.one` services accessible internally
- [ ] Internal latency acceptable (<100ms added)
- [ ] Large file transfers work (Nextcloud, Immich)
- [ ] Streaming works (Jellyfin, Plex)

### Phase 5: Cleanup and Documentation (Week 3)

**Tasks**:
1. ⬜ Remove old cloud gateway Caddy configuration:
   - Cloud no longer needs to proxy to storage
   - Can simplify cloud Caddy config to only serve its own services
2. ⬜ Update documentation:
   - Update `CLAUDE.md` with new architecture
   - Update `docs/architecture/overview.md`
   - Mark task-122 and task-123 as completed
3. ⬜ Monitor for one week:
   - Check for any service disruptions
   - Verify certificate renewals work
   - Monitor Cloudflare Tunnel health

**Success Criteria**:
- [ ] All services operational via Cloudflare Tunnels
- [ ] No split-horizon DNS complexity
- [ ] Documentation updated
- [ ] Stable for 1 week with no issues

---

## Security Considerations

### Advantages of Cloudflare Tunnel

1. **No Inbound Firewall Rules Required**:
   - Tunnels are outbound-only connections
   - No need to expose ports 80/443 to internet
   - Works behind CGNAT/dynamic IPs

2. **Cloudflare WAF Protection**:
   - All traffic goes through Cloudflare's edge network
   - DDoS protection included
   - Rate limiting and bot detection

3. **TLS Encryption**:
   - End-to-end encryption maintained (client → Cloudflare → Tunnel → Caddy → Service)
   - Cloudflare can inspect traffic (if configured) or pass-through (if using Full/Strict TLS mode)

### Security Checklist

**Firewall Configuration**:
- [ ] Close ports 80/443 on cloud host (no longer needed)
- [ ] Close ports 80/443 on storage host (no longer needed)
- [ ] Keep Tailscale port open (41641 UDP)
- [ ] Keep SSH port open (22 TCP) for management

**Cloudflare Tunnel Credentials**:
- [ ] Tunnel credentials stored in sops-nix (encrypted)
- [ ] Credentials have appropriate file permissions (0440, owner cloudflared)
- [ ] No credentials in git repository

**Authentication**:
- [ ] Authelia still required for protected services
- [ ] Services in `bypassAuth` list have their own authentication
- [ ] No services accidentally exposed without authentication

**TLS Mode**:
- [ ] Cloudflare TLS mode set to "Full (Strict)" for both domains
- [ ] Ensures end-to-end encryption
- [ ] Cloudflare validates origin certificates

**Monitoring**:
- [ ] Set up Cloudflare Tunnel health monitoring
- [ ] Alert on tunnel disconnection
- [ ] Monitor for authentication failures

---

## Cost Analysis

### Current Cost (Estimated)

| Item | Cost/Month | Notes |
|------|------------|-------|
| Cloud VPS | $5-10 | Small VPS (1-2 vCPU, 1-2GB RAM) |
| Storage VPS | $20-40 | Larger VPS for media storage |
| Domains | $2 | arsfeld.one, rosenfeld.one |
| Cloudflare | $0 | Free plan |
| **Total** | **$27-52** | |

### Dual Tunnel Cost (This Plan)

| Item | Cost/Month | Notes |
|------|------------|-------|
| Cloud VPS | $5-10 | Keep existing VPS |
| Storage VPS | $20-40 | Keep existing VPS |
| Domains | $2 | Both domains needed |
| Cloudflare | $0 | Free plan (2 tunnels supported) |
| **Total** | **$27-52** | **No cost change** |

### Single Tunnel Cost (Task-122)

| Item | Cost/Month | Notes |
|------|------------|-------|
| Cloud VPS | $0 | **Decommissioned** |
| Storage VPS | $20-40 | Keep existing VPS |
| Domains | $1 | Only arsfeld.one needed |
| Cloudflare | $0 | Free plan (1 tunnel) |
| **Total** | **$21-41** | **Save $6-11/month** |

### Cost Comparison Summary

- **Dual Tunnel (task-123)**: No cost change from current
- **Single Tunnel (task-122)**: Save $6-11/month (~$75-130/year)

**Long-term**: Task-122's single-tunnel approach is more cost-efficient. However, the dual-tunnel approach preserves optionality and is faster to implement.

---

## Operational Complexity Comparison

### Current Architecture (Split-Horizon)

**Complexity Level**: ⚠️⚠️⚠️⚠️ High

- Split-horizon DNS requires understanding of two different paths
- Must maintain two Caddy configurations (cloud and storage)
- Router DNS overrides hidden from main configuration
- Debugging requires checking both internal and external paths
- Service changes require deploying to both hosts

### Dual Tunnel Architecture (Task-123)

**Complexity Level**: ⚠️⚠️⚠️ Medium-High

- Two separate domains to manage
- Two Cloudflare Tunnels to monitor
- Two Caddy instances (but no longer duplicated config)
- Two ACME setups
- Two hosts to maintain
- **Advantage**: Unified routing (no split-horizon)
- **Advantage**: Clear domain separation by function

### Single Tunnel Architecture (Task-122)

**Complexity Level**: ⚠️⚠️ Medium-Low

- One domain to manage
- One Cloudflare Tunnel to monitor
- One Caddy instance
- One ACME setup
- One host to maintain
- **Advantage**: Simplest possible architecture
- **Advantage**: Lowest operational overhead

### Complexity Summary

| Aspect | Current | Dual Tunnel | Single Tunnel |
|--------|---------|-------------|---------------|
| **Hosts** | 2 (cloud, storage) | 2 (cloud, storage) | 1 (storage) |
| **Caddy Instances** | 2 (duplicated) | 2 (independent) | 1 |
| **DNS Systems** | 2 (Cloudflare + Blocky) | 1 (Cloudflare) | 1 (Cloudflare) |
| **Routing Paths** | 2 (internal/external) | 1 (unified) | 1 (unified) |
| **Certificate Management** | 2 (cloud, storage) | 2 (cloud, storage) | 1 (storage) |
| **Tunnel Configuration** | 0 | 2 | 1 |
| **Service Migration** | N/A | None needed | Required |

**Recommendation**: For operational simplicity, task-122 (single tunnel) is superior. However, dual tunnel is less risky and faster to deploy.

---

## Migration Path to Single Tunnel (Future Consolidation)

If you later decide to consolidate to task-122's single-tunnel architecture:

### Migration Steps

1. **Phase 1: Move Cloud Services to Storage** (2-3 weeks)
   - Migrate Authelia, LLDAP, Dex to storage
   - Update service configurations to use storage-hosted auth
   - Test authentication flow

2. **Phase 2: Migrate Cloud Domain Services** (1 week)
   - Move remaining cloud services (OwnTracks, Vault, etc.) to storage
   - Update DNS: `*.rosenfeld.one` → storage tunnel
   - Verify all services operational

3. **Phase 3: Decommission Cloud Tunnel** (1 week)
   - Stop cloudflared on cloud host
   - Delete cloud Cloudflare Tunnel
   - Remove `*.rosenfeld.one` DNS records (or redirect to storage)

4. **Phase 4: Decommission Cloud Host** (1 week)
   - Backup any remaining cloud data
   - Shut down cloud VPS
   - Cancel cloud hosting subscription

**Total Time**: 5-6 weeks (similar to task-122's initial migration)

**Advantage of Starting with Dual Tunnel**:
- Proves Cloudflare Tunnel concept with lower risk
- Allows time to evaluate if consolidation is truly needed
- Can keep cloud services separate if desired
- Reversible decision

---

## Rollback Strategy

### Level 1: Rollback DNS Only (Fastest)

**When**: Service disruption, tunnel issues, or need immediate rollback

**Steps**:
1. Change Cloudflare DNS records from "Proxied" (orange cloud) to "DNS only" (gray cloud)
   - Reverts to old routing immediately
2. Re-enable split-horizon DNS on router:
   ```bash
   # Edit hosts/router/services/dns.nix
   # Re-add: "*.arsfeld.one" = "100.118.254.136";
   just deploy router
   ```
3. Traffic flows through old path within 5 minutes (DNS TTL)

**Impact**: Minimal - services stay up, just change routing

### Level 2: Rollback Tunnel Configuration

**When**: Tunnel-specific issues, need to disable tunnels

**Steps**:
1. Stop cloudflared on both hosts:
   ```bash
   ssh storage systemctl stop cloudflared
   ssh cloud systemctl stop cloudflared
   ```
2. Execute Level 1 rollback (DNS changes)
3. NixOS configuration can be reverted with git:
   ```bash
   git revert <commit-hash>
   just deploy cloud
   just deploy storage
   ```

**Impact**: Low - old architecture still functional

### Level 3: Full Rollback (Complete Reversion)

**When**: Need to completely abandon Cloudflare Tunnel approach

**Steps**:
1. Delete Cloudflare Tunnels from dashboard
2. Remove tunnel NixOS modules from repository:
   ```bash
   git rm hosts/storage/services/cloudflare-tunnel.nix
   git rm hosts/cloud/services/cloudflare-tunnel.nix
   git commit -m "rollback: remove Cloudflare Tunnel implementation"
   ```
3. Deploy both hosts to remove cloudflared
4. Execute Level 1 rollback for DNS
5. Remove tunnel credentials from sops-nix

**Impact**: Medium - requires configuration changes but no data loss

### Rollback Decision Matrix

| Issue | Severity | Rollback Level | Recovery Time |
|-------|----------|----------------|---------------|
| Single service down | Low | None (fix service) | <1 hour |
| Tunnel intermittent | Medium | Level 1 (DNS) | <15 min |
| Tunnel completely down | High | Level 1 (DNS) | <15 min |
| Performance issues | Medium | Level 1 (DNS) | <15 min |
| Cloudflare outage | High | Level 1 (DNS) | <15 min |
| Need to abandon approach | Low | Level 3 (Full) | <2 hours |

**Safeguards**:
- Old architecture remains functional during entire migration
- Can rollback at any phase without data loss
- DNS changes are quick and reversible
- No destructive operations until Phase 5 (cleanup)

---

## Testing Strategy

### Pre-Deployment Testing

1. **Tunnel Connectivity Test**:
   - Verify tunnel shows "Healthy" in Cloudflare dashboard
   - Check `cloudflared` logs for errors:
     ```bash
     journalctl -u cloudflared -f
     ```

2. **Service Accessibility Test**:
   - Test each service subdomain resolves correctly
   - Verify TLS certificates valid
   - Check authentication flows work

3. **Performance Test**:
   - Measure latency: `ping jellyfin.arsfeld.one`
   - Test large file upload (Nextcloud)
   - Test streaming (Jellyfin/Plex)
   - Verify acceptable performance

### Post-Deployment Testing

1. **External Access Test** (from outside Tailscale):
   - Access services from mobile network (not on WiFi)
   - Verify all services accessible
   - Test authentication flows

2. **Internal Access Test** (from Tailscale/LAN):
   - Access services from LAN
   - Verify routing through Cloudflare (not direct)
   - Measure latency difference (expect 20-50ms increase)

3. **Cross-Service Communication Test**:
   - Verify storage services can authenticate against cloud Authelia
   - Test any integrations between cloud and storage services
   - Verify Tailscale communication still works

4. **Monitoring Test**:
   - Set up monitoring for tunnel health
   - Create alerts for tunnel disconnection
   - Monitor for 1 week before considering stable

### Load Testing (Optional)

**For high-traffic services**:
- Use `ab` (Apache Bench) or `wrk` to load test
- Test concurrent connections: `ab -n 1000 -c 10 https://jellyfin.arsfeld.one/`
- Verify tunnel can handle expected load
- Cloudflare free plan has rate limits - verify not hitting them

---

## Acceptance Criteria Completion

### AC#1: Document analyzing dual-tunnel approach vs single-tunnel migration
✅ **Complete** - See "Executive Summary" and "Comparison to Task-122" sections

### AC#2: Cloudflare Tunnel configuration for storage host (*.arsfeld.one)
✅ **Complete** - See "Tunnel 1: Storage" section with full NixOS config

### AC#3: Cloudflare Tunnel configuration for cloud host (*.rosenfeld.one)
✅ **Complete** - See "Tunnel 2: Cloud" section with full NixOS config

### AC#4: Service domain assignment strategy
✅ **Complete** - See "Service Distribution" section with full service lists

### AC#5: DNS configuration for both domains (eliminate split-horizon)
✅ **Complete** - See "DNS Configuration Changes" section

### AC#6: Certificate management for dual domains
✅ **Complete** - See "Certificate Management" section (keep existing ACME)

### AC#7: Implementation phases (tunnel deployment, DNS cutover)
✅ **Complete** - See "Implementation Plan" with 5 phases

### AC#8: Cost analysis (2 hosts + 2 tunnels vs 1 host + 1 tunnel)
✅ **Complete** - See "Cost Analysis" section (dual tunnel: $27-52/mo, single tunnel: $21-41/mo)

### AC#9: Operational complexity comparison
✅ **Complete** - See "Operational Complexity Comparison" section

### AC#10: Migration path if later wanting to consolidate to single host
✅ **Complete** - See "Migration Path to Single Tunnel" section

---

## Recommendations

### Short-Term (0-3 Months)

**Implement Dual Tunnel Architecture** (This Plan - Task-123)

**Reasoning**:
- ✅ Faster implementation (2-3 weeks vs 6 weeks for task-122)
- ✅ Lower risk (no service migration required)
- ✅ Easy rollback (just DNS changes)
- ✅ Proves Cloudflare Tunnel concept
- ✅ Eliminates split-horizon DNS complexity immediately

**Trade-offs**:
- ❌ Higher ongoing cost ($6-11/month more than single tunnel)
- ❌ More operational complexity (2 hosts, 2 tunnels)
- ❌ Still maintaining cloud host

### Medium-Term (3-6 Months)

**Evaluate Consolidation Need**

After dual tunnels are stable, evaluate:
1. Is cloud host truly needed? (are cloud services heavily used?)
2. Is the additional cost justified? ($75-130/year)
3. Is operational complexity acceptable? (2 hosts to maintain)

**If "Yes" to all**: Keep dual tunnel architecture
**If "No" to any**: Proceed with consolidation to single tunnel

### Long-Term (6+ Months)

**Consider Migration to Single Tunnel** (Task-122)

If cloud host is not essential:
1. Follow "Migration Path to Single Tunnel" section
2. Migrate cloud services to storage (4-6 weeks)
3. Decommission cloud host
4. Reduce to single tunnel on storage

**Final State**:
- One host (storage)
- One domain (*.arsfeld.one)
- One Cloudflare Tunnel
- Lowest cost and complexity

---

## Conclusion

The **dual Cloudflare Tunnel architecture** (task-123) is a **pragmatic intermediate step** that:

1. **Eliminates the current complexity** (split-horizon DNS)
2. **Requires minimal changes** (no service migration)
3. **Preserves future options** (can consolidate later if desired)
4. **Low risk deployment** (easy rollback at any phase)

However, **task-122's single-tunnel architecture is the superior long-term solution** due to:
1. Lower operational cost ($75-130/year savings)
2. Simpler operations (one host, one tunnel)
3. Reduced maintenance burden

**Recommended Path**:
1. **Implement dual tunnel now** (task-123) - 2-3 weeks
2. **Operate for 3-6 months** - validate Cloudflare Tunnel approach
3. **Evaluate consolidation** - assess if cloud host is truly needed
4. **Migrate to single tunnel** (task-122) - 4-6 weeks if consolidation makes sense

This approach provides **maximum flexibility** with **minimum risk** while moving toward the optimal architecture incrementally.

---

**Next Steps**: Review this plan, then proceed to Phase 0 (Preparation) to begin implementation.
