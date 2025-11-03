# Hybrid Dual Cloudflare Tunnel Architecture Plan (Task-124)

**Alternative Architecture**: Best of both worlds - dual tunnels with single domain

**Date**: 2025-11-01
**Status**: Planning Phase
**Related**: task-122 (single-tunnel), task-123 (dual-tunnel dual-domain)

---

## Executive Summary

This plan proposes a **hybrid dual Cloudflare Tunnel architecture** that combines the best aspects of task-122 (simplicity of single domain) and task-123 (no service migration needed). Instead of choosing between simplicity and ease of implementation, this approach achieves both:

- **Dual tunnels** (like task-123): Cloud and storage each have their own Cloudflare Tunnel
- **Single domain** (like task-122): All services use `*.arsfeld.one` only
- **Intelligent routing**: Cloudflare routes each subdomain to the correct tunnel based on service location
- **Independent hosts**: Each host serves only its own services (no proxying between hosts)
- **No migration**: Cloud services stay on cloud, storage services stay on storage

### The Key Innovation

Unlike task-123 which requires two domains (`*.arsfeld.one` and `*.rosenfeld.one`), this hybrid approach uses **wildcard DNS with automated cloud service overrides**:

- **Wildcard default**: `*.arsfeld.one` → Storage Tunnel (for 70+ services)
- **Explicit cloud services**: Script on cloud automatically updates 13 cloud service CNAMEs → Cloud Tunnel
- **Direct local access**: Internal clients use simplified split-horizon DNS for performance

```
External Clients:
  Cloudflare DNS (*.arsfeld.one)
    ├─ auth.arsfeld.one → Cloud Tunnel → Cloud Caddy → Authelia (explicit CNAME)
    ├─ vault.arsfeld.one → Cloud Tunnel → Cloud Caddy → Vault (explicit CNAME)
    └─ jellyfin.arsfeld.one → Storage Tunnel → Storage Caddy → Jellyfin (wildcard)

Internal Clients (LAN/Tailscale):
  Router DNS: *.arsfeld.one → Storage IP (direct, no Cloudflare hop)
```

### Comparison Matrix

| Aspect | Current | Task-122 | Task-123 | **Task-124 (This)** |
|--------|---------|----------|----------|-------------------|
| **Architecture** | Split-horizon DNS | Single tunnel | Dual tunnel, dual domain | **Dual tunnel, single domain** |
| **Domains** | 1 (arsfeld.one) | 1 (arsfeld.one) | 2 (arsfeld.one + rosenfeld.one) | **1 (arsfeld.one)** |
| **Hosts** | 2 (cloud + storage) | 1 (storage only) | 2 (cloud + storage) | **2 (cloud + storage)** |
| **Service Migration** | N/A | Required (6+ services) | Not required | **Not required** |
| **Caddy Proxying** | Cloud → Storage | N/A (single host) | None (independent) | **None (independent)** |
| **Split-Horizon DNS** | Yes (complex) | No | No | **Yes (simplified)** |
| **Monthly Cost** | $27-52 | $21-41 (saves $6-11) | $27-52 (no change) | **$27-52 (no change)** |
| **Implementation Time** | N/A | 6 weeks (phased) | 2-3 weeks | **2-3 weeks** |
| **Risk Level** | N/A | Medium (migration) | Low (no migration) | **Low (no migration)** |
| **Rollback Difficulty** | N/A | Medium (services moved) | Easy (DNS only) | **Easy (DNS only)** |
| **Future Consolidation** | N/A | N/A (already done) | Possible (4-6 weeks) | **Possible (4-6 weeks)** |
| **Operational Complexity** | High (split-horizon) | Low (single host) | Medium (2 hosts, 2 domains) | **Medium-Low (2 hosts, 1 domain)** |

### Why This Hybrid Approach?

**vs Task-122 (Single Tunnel)**:
- ✅ Faster implementation (2-3 weeks vs 6 weeks)
- ✅ Lower risk (no service migration)
- ✅ Easy rollback (just DNS changes)
- ✅ Keeps both hosts operational (can decommission later if desired)
- ❌ Slightly higher cost ($6-11/month more)
- ❌ More operational overhead (2 hosts to maintain)

**vs Task-123 (Dual Tunnel, Dual Domain)**:
- ✅ Simpler DNS (one domain vs two)
- ✅ No need for second domain setup/cost
- ✅ Users only remember one domain
- ✅ Easier certificate management (single domain wildcard)
- ✅ Same implementation speed (2-3 weeks)
- ✅ Same low risk profile

**vs Current Architecture**:
- ✅ Simplifies split-horizon DNS (wildcard instead of per-service)
- ✅ Eliminates cloud as redundant proxy
- ✅ Eliminates duplicate Caddy configurations
- ✅ Makes service distribution explicit
- ✅ Maintains current service locations (no migration)
- ✅ Maintains direct local access for performance
- ✅ Same infrastructure cost
- ✅ Automated DNS management via script (no manual updates)

### Recommendation

**This hybrid approach (task-124) is the optimal choice** because it:
1. **Eliminates current complexity** (split-horizon DNS, duplicate Caddy configs)
2. **Requires minimal effort** (2-3 weeks, no service migration)
3. **Reduces operational burden** (no proxying, independent hosts)
4. **Maintains flexibility** (can consolidate to task-122 later if desired)
5. **Lowest risk** (easy rollback at any phase)
6. **Maintains direct local access** (internal clients bypass Cloudflare for performance)
7. **Automated DNS management** (script handles cloud services, wildcard covers storage)

---

## Current Architecture Pain Points

*(Inherited from task-122 and task-123 analyses)*

### 1. Hidden Caddy Duplication
Both cloud and storage run **identical** Caddy configurations, but this is hidden by DNS routing:
- **External clients**: DNS points to cloud → Cloud Caddy proxies to Storage Caddy → Service
- **Internal clients**: DNS override points to storage → Storage Caddy → Service (direct)
- **Problem**: Maintenance burden, confusing paths, storage already self-sufficient

### 2. Split-Horizon DNS Confusion
Current DNS configuration:
```nix
# Cloudflare (external): *.arsfeld.one → Cloud public IP
# Blocky (internal): *.arsfeld.one → 100.118.254.136 (storage)
```
- External and internal traffic follow completely different paths
- Not obvious from code which path is used
- Debugging requires understanding both paths
- Can't easily test "external" behavior from internal network

### 3. Cloud as Redundant Proxy
- Cloud adds latency without clear benefit
- External clients: User → Cloudflare → Cloud → Storage → Service (2 hops)
- Internal clients: User → Storage → Service (direct)
- **Root Issue**: Storage is already authoritative, cloud is just pass-through

### 4. Implicit Service Distribution
Services defined in two locations with different patterns:
- `modules/constellation/services.nix` - Native systemd services
- `modules/constellation/media.nix` - Containerized services
- Not clear from config which host actually runs each service
- Hard to migrate services between patterns

---

## Proposed Hybrid Architecture

### High-Level Design

```
┌─────────────────────────────────────────────────────────────────┐
│                         Internet                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                    ┌─────────┴──────────┐
                    │   Cloudflare DNS   │
                    │   (*.arsfeld.one)  │
                    │  Intelligent       │
                    │  Subdomain Routing │
                    └─────────┬──────────┘
                              │
                ┌─────────────┴─────────────┐
                │                           │
        ┌───────▼──────┐            ┌──────▼───────┐
        │  CF Tunnel 1 │            │  CF Tunnel 2 │
        │  (Cloud)     │            │  (Storage)   │
        │  Outbound    │            │  Outbound    │
        └───────┬──────┘            └──────┬───────┘
                │                           │
      ┌─────────▼─────────┐       ┌────────▼────────┐
      │   Cloud Host      │       │  Storage Host   │
      │ (100.118.254.136) │       │ (100.118.254.137│
      │                   │       │      )          │
      │ Caddy (localhost) │       │ Caddy (localhost│
      │ ├─ auth           │       │      )          │
      │ ├─ dex            │       │ ├─ jellyfin     │
      │ ├─ users (lldap)  │       │ ├─ plex         │
      │ ├─ vault          │       │ ├─ overseerr    │
      │ ├─ yarr           │       │ ├─ sonarr       │
      │ ├─ mqtt           │       │ ├─ radarr       │
      │ ├─ owntracks      │       │ ├─ gitea        │
      │ ├─ thelounge      │       │ ├─ nextcloud    │
      │ ├─ ntfy           │       │ ├─ immich       │
      │ ├─ whoogle        │       │ ├─ n8n          │
      │ └─ 4 more         │       │ └─ 60+ more     │
      └───────────────────┘       └─────────────────┘
                │                           │
      ┌─────────▼───────────────────────────▼──────┐
      │          Tailscale VPN                     │
      │          (bat-boa.ts.net)                  │
      │  - Internal access (service-to-service)    │
      │  - Management access (SSH, monitoring)     │
      └────────────────────────────────────────────┘
```

### Key Architectural Principles

1. **Single Domain, Multiple Tunnels**:
   - All services use `*.arsfeld.one` domain
   - Cloudflare routes each subdomain to correct tunnel based on ingress configuration
   - Example: `auth.arsfeld.one` → Cloud Tunnel, `jellyfin.arsfeld.one` → Storage Tunnel

2. **Independent Host Operations**:
   - Each host runs only its own services
   - Each host has its own Caddy instance (serves localhost only)
   - Each host has its own Cloudflare Tunnel daemon
   - **No proxying between hosts** (unlike current architecture)

3. **Cloudflare Intelligent Routing**:
   - Cloudflare DNS has CNAME records for each subdomain
   - Each CNAME points to the appropriate tunnel
   - Cloudflare edge automatically routes to correct tunnel

4. **No Split-Horizon DNS**:
   - All DNS (internal and external) points to Cloudflare
   - Consistent routing regardless of client location
   - Remove Blocky DNS overrides from router

5. **Tailscale for Service-to-Service Communication**:
   - Maintained for internal access and management
   - Storage services can reach cloud Authelia via `cloud.bat-boa.ts.net:9091`
   - Cross-host dependencies use Tailscale (not public internet)

---

## Service Distribution and Tunnel Mapping

### Cloud Host Services → Cloud Tunnel

**DNS**: `<service>.arsfeld.one` → Cloud Tunnel CNAME

#### Authentication & Identity Stack
- `auth.arsfeld.one` - Authelia SSO (port 9091)
- `dex.arsfeld.one` - OpenID Connect provider (default port)
- `users.arsfeld.one` - LLDAP directory (port 17170)

#### Communication Services
- `mqtt.arsfeld.one` - Mosquitto MQTT broker (port 1883, TCP mode)
- `owntracks.arsfeld.one` - Location tracking (port 8083)
- `thelounge.arsfeld.one` - IRC web client (port 9000 container)

#### Utility Services
- `vault.arsfeld.one` - Vault secrets manager (port 8000)
- `yarr.arsfeld.one` - RSS reader (port 7070)
- `whoogle.arsfeld.one` - Privacy search proxy (port 5000)
- `search.arsfeld.one` - Alias for whoogle (port 5000)

#### Media & Content Services
- `metube.arsfeld.one` - YouTube downloader (default port)
- `invidious.arsfeld.one` - YouTube frontend (default port)
- `dns.arsfeld.one` - AdGuard Home (default port)

#### Notifications
- `ntfy.arsfeld.one` - Push notifications (default port)

**Total**: ~13 services on cloud (minimal, infrastructure-focused)

### Storage Host Services → Storage Tunnel

**DNS**: `<service>.arsfeld.one` → Storage Tunnel CNAME

#### Media Streaming
- `jellyfin.arsfeld.one` - Jellyfin media server (port 8096)
- `plex.arsfeld.one` - Plex media server (port 32400)
- `audiobookshelf.arsfeld.one` - Audiobook streaming (port 13378)
- `jf.arsfeld.one` - Jellyfin mobile app redirect (port 3831)

#### Media Acquisition
- `sonarr.arsfeld.one` - TV show management (port 8989)
- `radarr.arsfeld.one` - Movie management (port 7878)
- `prowlarr.arsfeld.one` - Indexer manager (port 9696)
- `bazarr.arsfeld.one` - Subtitle management (port 6767)
- `overseerr.arsfeld.one` - Media request system (port 5055)
- `autobrr.arsfeld.one` - Torrent automation (port 7474)
- `jackett.arsfeld.one` - Indexer proxy (port 9117)
- `pinchflat.arsfeld.one` - YouTube archiver (port 8945)
- `lidarr.arsfeld.one` - Music management (port 8686)
- `whisparr.arsfeld.one` - Adult content management (port 6969)
- `headphones.arsfeld.one` - Music automation (port 8787)
- `mediamanager.arsfeld.one` - All-in-one media manager (port 8000)

#### Download Clients
- `transmission.arsfeld.one` - Transmission torrent client (port 9091)
- `qbittorrent.arsfeld.one` - qBittorrent web UI (port 8080)
- `qui.arsfeld.one` - Modern qBittorrent UI (port 7476)
- `sabnzbd.arsfeld.one` - Usenet downloader (port 8080)

#### File Management & Storage
- `nextcloud.arsfeld.one` - Cloud storage (port 8099)
- `filestash.arsfeld.one` - File browser (port 8334)
- `filebrowser.arsfeld.one` - Alternative file browser (port 38080)
- `filerun.arsfeld.one` - File manager (port 6000)
- `syncthing.arsfeld.one` - File synchronization (port 8384)
- `resilio.arsfeld.one` - Resilio Sync (port 9000)
- `seafile.arsfeld.one` - File sync/share (port 8082)
- `duplicati.arsfeld.one` - Backup solution (port 8200)
- `restic.arsfeld.one` - Restic backup (port 8000)

#### Development & Infrastructure
- `gitea.arsfeld.one` - Git hosting (port 3001)
- `code.arsfeld.one` - Code Server (VS Code in browser) (port 4444)
- `attic.arsfeld.one` - Nix binary cache (port 8080)
- `n8n.arsfeld.one` - Workflow automation (port 5678)
- `windmill.arsfeld.one` - Workflow engine (port 8001)
- `ollama.arsfeld.one` - LLM UI (port 30198)
- `ollama-api.arsfeld.one` - LLM API (port 11434)

#### Content Management & Media
- `stash.arsfeld.one` - Media organizer (port 9999)
- `kavita.arsfeld.one` - Manga/comics reader (port 5000)
- `komga.arsfeld.one` - Alternative comics reader (default port)
- `photoprism.arsfeld.one` - Photo management (port 2342)
- `photos.arsfeld.one` - Alias for photoprism (port 2342)
- `immich.arsfeld.one` - Photo backup/sharing (port 15777)
- `romm.arsfeld.one` - ROM manager (port 8998)
- `openarchiver.arsfeld.one` - Email archiving (port 3000)

#### Home Automation
- `hass.arsfeld.one` - Home Assistant (port 8123)
- `grocy.arsfeld.one` - Groceries management (port 9283)
- `home.arsfeld.one` - Home dashboard (port 8085)
- `www.arsfeld.one` - WWW redirect (port 8085)

#### Monitoring & Admin
- `grafana.arsfeld.one` - Metrics visualization (port 3010)
- `netdata.arsfeld.one` - System monitoring (port 19999)
- `scrutiny.arsfeld.one` - Disk health monitoring (port 9998)
- `tautulli.arsfeld.one` - Plex statistics (port 8181)
- `speedtest.arsfeld.one` - Network speed test (port 8765)

#### Utilities & Tools
- `bitmagnet.arsfeld.one` - Torrent indexer (port 3333)
- `fileflows.arsfeld.one` - File processing (port 19200)
- `stirling.arsfeld.one` - PDF tools (port 9284)
- `threadfin.arsfeld.one` - M3U proxy (port 34400)
- `flaresolverr.arsfeld.one` - Cloudflare bypass (port 8191)
- `ohdio.arsfeld.one` - Podcast manager (port 4000)
- `actual.arsfeld.one` - Budget manager (port 5006)
- `remotely.arsfeld.one` - Remote desktop (port 5000)
- `yarr-dev.arsfeld.one` - RSS reader dev (port 7070)

**Total**: ~70+ services on storage (media, apps, development)

### Cross-Host Dependencies

**Authelia Integration**:
- Storage services requiring authentication forward to `cloud.bat-boa.ts.net:9091` (Tailscale)
- Maintains existing forward_auth configuration
- No changes needed to service authentication flows
- Example: User → Storage Tunnel → Jellyfin → Forward auth to cloud Authelia → Response

**Service-to-Service Communication**:
- All cross-host communication uses Tailscale (`*.bat-boa.ts.net`)
- Examples: Sonarr → Prowlarr indexers, Overseerr → Radarr/Sonarr APIs
- No dependencies on public `*.arsfeld.one` domains for internal communication

---

## Cloudflare Tunnel Configuration

### Tunnel 1: Cloud Host (`cloud-arsfeld`)

**NixOS Configuration** (`hosts/cloud/services/cloudflare-tunnel.nix`):

```nix
{ config, pkgs, ... }:

{
  services.cloudflared = {
    enable = true;
    tunnels = {
      "cloud-arsfeld" = {
        credentialsFile = config.sops.secrets."cloudflare/tunnel-cloud-creds".path;
        default = "http_status:404";

        ingress = {
          # Authentication services
          "auth.arsfeld.one" = "http://localhost:9091";
          "dex.arsfeld.one" = "http://localhost:5556";
          "users.arsfeld.one" = "http://localhost:17170";

          # Communication services
          "owntracks.arsfeld.one" = "http://localhost:8083";
          "thelounge.arsfeld.one" = "http://localhost:9000";

          # Utility services
          "vault.arsfeld.one" = "http://localhost:8000";
          "yarr.arsfeld.one" = "http://localhost:7070";
          "whoogle.arsfeld.one" = "http://localhost:5000";
          "search.arsfeld.one" = "http://localhost:5000";
          "metube.arsfeld.one" = "http://localhost:8081";
          "invidious.arsfeld.one" = "http://localhost:3000";
          "dns.arsfeld.one" = "http://localhost:3000";

          # Notifications
          "ntfy.arsfeld.one" = "http://localhost:8080";

          # MQTT (TCP mode for non-HTTP service)
          "mqtt.arsfeld.one" = {
            service = "tcp://localhost:1883";
          };

          # Catch-all for any cloud service not explicitly listed
          # Routes through Caddy which handles service routing
          "*.arsfeld.one" = "http://localhost:80";
        };
      };
    };
  };

  # Secret configuration (cloud already using sops-nix PoC)
  sops.secrets."cloudflare/tunnel-cloud-creds" = {
    sopsFile = ../../secrets/sops/cloud-poc.yaml;
    mode = "0440";
    owner = "cloudflared";
    group = "cloudflared";
  };
}
```

**Cloudflare Dashboard Configuration**:
1. Navigate to Zero Trust → Networks → Tunnels
2. Create new tunnel: `cloud-arsfeld`
3. Download credentials JSON
4. Add credentials to sops:
   ```bash
   # Add to secrets/sops/cloud-poc.yaml
   nix develop -c sops secrets/sops/cloud-poc.yaml
   # Add: cloudflare.tunnel-cloud-creds: <paste JSON>
   ```
5. Deploy to cloud: `just deploy cloud`

### Tunnel 2: Storage Host (`storage-arsfeld`)

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
          # Media streaming services
          "jellyfin.arsfeld.one" = "http://localhost:8096";
          "plex.arsfeld.one" = "http://localhost:32400";
          "audiobookshelf.arsfeld.one" = "http://localhost:13378";
          "jf.arsfeld.one" = "http://localhost:3831";

          # Media acquisition services
          "sonarr.arsfeld.one" = "http://localhost:8989";
          "radarr.arsfeld.one" = "http://localhost:7878";
          "prowlarr.arsfeld.one" = "http://localhost:9696";
          "bazarr.arsfeld.one" = "http://localhost:6767";
          "overseerr.arsfeld.one" = "http://localhost:5055";
          "autobrr.arsfeld.one" = "http://localhost:7474";
          "jackett.arsfeld.one" = "http://localhost:9117";
          "pinchflat.arsfeld.one" = "http://localhost:8945";
          "lidarr.arsfeld.one" = "http://localhost:8686";
          "whisparr.arsfeld.one" = "http://localhost:6969";
          "headphones.arsfeld.one" = "http://localhost:8787";
          "mediamanager.arsfeld.one" = "http://localhost:8000";

          # Download clients
          "transmission.arsfeld.one" = "http://localhost:9091";
          "qbittorrent.arsfeld.one" = "http://localhost:8080";
          "qui.arsfeld.one" = "http://localhost:7476";
          "sabnzbd.arsfeld.one" = "http://localhost:8080";

          # File management
          "nextcloud.arsfeld.one" = "http://localhost:8099";
          "filestash.arsfeld.one" = "http://localhost:8334";
          "filebrowser.arsfeld.one" = "http://localhost:38080";
          "filerun.arsfeld.one" = "http://localhost:6000";
          "syncthing.arsfeld.one" = "http://localhost:8384";
          "resilio.arsfeld.one" = "http://localhost:9000";
          "seafile.arsfeld.one" = "http://localhost:8082";
          "duplicati.arsfeld.one" = "http://localhost:8200";
          "restic.arsfeld.one" = "http://localhost:8000";

          # Development & infrastructure
          "gitea.arsfeld.one" = "http://localhost:3001";
          "code.arsfeld.one" = "http://localhost:4444";
          "attic.arsfeld.one" = "http://localhost:8080";
          "n8n.arsfeld.one" = "http://localhost:5678";
          "windmill.arsfeld.one" = "http://localhost:8001";
          "ollama.arsfeld.one" = "http://localhost:30198";
          "ollama-api.arsfeld.one" = "http://localhost:11434";

          # Content management
          "stash.arsfeld.one" = "http://localhost:9999";
          "kavita.arsfeld.one" = "http://localhost:5000";
          "photoprism.arsfeld.one" = "http://localhost:2342";
          "photos.arsfeld.one" = "http://localhost:2342";
          "immich.arsfeld.one" = "http://localhost:15777";
          "romm.arsfeld.one" = "http://localhost:8998";
          "openarchiver.arsfeld.one" = "http://localhost:3000";

          # Home automation
          "hass.arsfeld.one" = "http://localhost:8123";
          "grocy.arsfeld.one" = "http://localhost:9283";
          "home.arsfeld.one" = "http://localhost:8085";
          "www.arsfeld.one" = "http://localhost:8085";

          # Monitoring
          "grafana.arsfeld.one" = "http://localhost:3010";
          "netdata.arsfeld.one" = "http://localhost:19999";
          "scrutiny.arsfeld.one" = "http://localhost:9998";
          "tautulli.arsfeld.one" = "http://localhost:8181";
          "speedtest.arsfeld.one" = "http://localhost:8765";

          # Utilities
          "bitmagnet.arsfeld.one" = "http://localhost:3333";
          "fileflows.arsfeld.one" = "http://localhost:19200";
          "stirling.arsfeld.one" = "http://localhost:9284";
          "threadfin.arsfeld.one" = "http://localhost:34400";
          "flaresolverr.arsfeld.one" = "http://localhost:8191";
          "ohdio.arsfeld.one" = "http://localhost:4000";
          "actual.arsfeld.one" = "http://localhost:5006";
          "remotely.arsfeld.one" = "http://localhost:5000";
          "yarr-dev.arsfeld.one" = "http://localhost:7070";

          # Catch-all route through Caddy for any service not explicitly listed
          "*.arsfeld.one" = "http://localhost:80";
        };
      };
    };
  };

  # Secret configuration (storage needs sops-nix migration - task-120)
  # For now, using ragenix secret until migration complete
  age.secrets.cloudflare-tunnel-storage-creds = {
    file = ../../secrets/cloudflare-tunnel-storage-creds.age;
    mode = "0440";
    owner = "cloudflared";
    group = "cloudflared";
  };

  # After task-120 migration complete, switch to:
  # sops.secrets."cloudflare/tunnel-storage-creds" = {
  #   sopsFile = ../../secrets/sops/storage.yaml;
  #   mode = "0440";
  #   owner = "cloudflared";
  #   group = "cloudflared";
  # };
}
```

**Cloudflare Dashboard Configuration**:
1. Navigate to Zero Trust → Networks → Tunnels
2. Create new tunnel: `storage-arsfeld`
3. Download credentials JSON
4. Add credentials to secrets:
   ```bash
   # Using ragenix (until task-120 complete)
   echo '<paste JSON>' | nix develop -c ragenix --rules secrets/secrets.nix -e cloudflare-tunnel-storage-creds.age --editor -

   # Or with sops-nix (after task-120):
   nix develop -c sops secrets/sops/storage.yaml
   # Add: cloudflare.tunnel-storage-creds: <paste JSON>
   ```
5. Deploy to storage: `just deploy storage`

### Special Considerations

**MQTT Service (Non-HTTP)**:
- MQTT uses TCP protocol, not HTTP
- Cloudflare Tunnel supports TCP mode: `service = "tcp://localhost:1883"`
- Clients connect to `mqtt.arsfeld.one:1883` via tunnel
- Alternatively, can keep MQTT Tailscale-only (not exposed via tunnel)

**WebSocket Services**:
- Jellyfin, Plex, Home Assistant use WebSockets
- Cloudflare Tunnel supports WebSocket by default
- No special configuration needed

**Large File Uploads**:
- Nextcloud, Immich handle large file uploads
- Cloudflare free plan: 100MB file size limit
- Consider Cloudflare Tunnel paid plan ($5/month) for larger uploads
- Or use Tailscale for large file transfers (`*.bat-boa.ts.net`)

---

## DNS Configuration

### Current State (Split-Horizon)

**External Clients** (public internet):
```
*.arsfeld.one → Cloudflare DNS → Cloud public IP → Cloud Caddy → Storage Caddy → Service
```

**Internal Clients** (Tailscale/LAN):
```
*.arsfeld.one → Router Blocky DNS override → 100.118.254.136 (storage) → Storage Caddy → Service
```

**Problem**: Two completely different paths depending on network location.

### New State (Hybrid Routing)

**External Clients** (internet):
```
*.arsfeld.one → Cloudflare DNS
    ├─ Wildcard: *.arsfeld.one → Storage Tunnel → Storage Caddy (70+ services)
    └─ Explicit CNAMEs: auth/vault/yarr/etc → Cloud Tunnel → Cloud Caddy (13 services)
```

**Internal Clients** (LAN/Tailscale):
```
*.arsfeld.one → Router DNS override → Storage IP (direct, no Cloudflare)
    - Direct local access to storage services (fast, no latency)
    - Cloud services still routed via Cloudflare (minimal traffic)
```

**Benefits**:
- ✅ Direct local access to storage (fast, no Cloudflare hop for 95% of traffic)
- ✅ Automated DNS management (script updates cloud services only)
- ✅ No manual DNS updates when adding storage services (wildcard covers them)
- ✅ Simplified split-horizon (one wildcard rule instead of 83+ per-service rules)
- ✅ External clients get Cloudflare protection and routing

### DNS Changes Required

#### 1. Cloudflare DNS Records

**Wildcard (default for all storage services)**:
```
Type: CNAME
Name: *
Target: <storage-tunnel-id>.cfargotunnel.com
Proxy: Yes (orange cloud)
TTL: Auto
```

**Explicit CNAMEs for cloud services** (automated via script):
```
Type: CNAME
Name: auth
Target: <cloud-tunnel-id>.cfargotunnel.com
Proxy: Yes (orange cloud)
TTL: Auto

Type: CNAME
Name: dex
Target: <cloud-tunnel-id>.cfargotunnel.com
...
(13 cloud services total)
```

**How it works**:
- Cloudflare prioritizes specific records over wildcard
- Cloud services (auth, vault, etc.) have explicit CNAMEs → Cloud Tunnel
- All other services fall through to wildcard → Storage Tunnel
- Adding new storage service = zero DNS work (covered by wildcard)
- Adding new cloud service = automated script updates DNS

#### 2. Automated DNS Management Script

**File**: `hosts/cloud/services/cloudflare-dns-sync.nix`

```nix
{ config, pkgs, lib, ... }:

let
  # Extract cloud services from constellation.services
  cloudServices = lib.attrNames (lib.filterAttrs
    (name: service: service.host == "cloud")
    config.media.gateway.services
  );

  # Cloudflare API script
  dnsSyncScript = pkgs.writeShellScript "cloudflare-dns-sync" ''
    set -euo pipefail

    ZONE_ID="$1"
    TUNNEL_ID="$2"
    DOMAIN="arsfeld.one"
    SERVICES="${lib.concatStringsSep " " cloudServices}"

    # Cloudflare API credentials from secrets
    CF_API_TOKEN=$(cat ${config.sops.secrets."cloudflare/api-token".path})

    for SERVICE in $SERVICES; do
      RECORD_NAME="$SERVICE"
      TUNNEL_TARGET="$TUNNEL_ID.cfargotunnel.com"

      echo "Updating DNS for $RECORD_NAME.$DOMAIN → $TUNNEL_TARGET"

      # Check if record exists
      RECORD_ID=$(curl -s -X GET \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$RECORD_NAME.$DOMAIN" \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        -H "Content-Type: application/json" \
        | ${pkgs.jq}/bin/jq -r '.result[0].id // empty')

      if [ -n "$RECORD_ID" ]; then
        # Update existing record
        curl -s -X PUT \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"CNAME\",\"name\":\"$RECORD_NAME\",\"content\":\"$TUNNEL_TARGET\",\"proxied\":true}" \
          | ${pkgs.jq}/bin/jq -r '.success'
      else
        # Create new record
        curl -s -X POST \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
          -H "Authorization: Bearer $CF_API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"CNAME\",\"name\":\"$RECORD_NAME\",\"content\":\"$TUNNEL_TARGET\",\"proxied\":true}" \
          | ${pkgs.jq}/bin/jq -r '.success'
      fi
    done

    echo "DNS sync complete for $(echo $SERVICES | wc -w) cloud services"
  '';
in
{
  # Cloudflare API token secret
  sops.secrets."cloudflare/api-token" = {
    sopsFile = ../../secrets/sops/cloud-poc.yaml;
    mode = "0440";
  };

  # Systemd service to sync DNS on deployment
  systemd.services.cloudflare-dns-sync = {
    description = "Sync Cloudflare DNS records for cloud services";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # Get tunnel ID from cloudflared config
      TUNNEL_ID=$(${pkgs.gnugrep}/bin/grep -oP 'tunnel:\s*\K[a-f0-9-]+' /etc/cloudflared/config.yml || echo "TUNNEL_ID_PLACEHOLDER")
      ZONE_ID="ZONE_ID_PLACEHOLDER"  # Replace with actual zone ID

      ${dnsSyncScript} "$ZONE_ID" "$TUNNEL_ID"
    '';
  };
}
```

**How to use**:
1. Add Cloudflare API token to secrets: `nix develop -c sops secrets/sops/cloud-poc.yaml`
2. Replace `ZONE_ID_PLACEHOLDER` with actual Cloudflare zone ID
3. Import in `hosts/cloud/configuration.nix`
4. On deployment, service automatically updates DNS for all cloud services
5. Adding new cloud service to `services.nix` = automatic DNS update on next deploy

**Manual trigger** (if needed):
```bash
ssh cloud systemctl restart cloudflare-dns-sync
```

#### 3. Keep Simplified Split-Horizon DNS

**File**: `hosts/router/services/dns.nix`

**Update (not remove)** to simplified wildcard:
```nix
customDNS = {
  mapping = {
    # Wildcard: direct to storage for fast local access
    "*.arsfeld.one" = "100.118.254.137";  # Storage Tailscale IP
  };
};
```

**Deploy**:
```bash
just deploy router
```

**How it works**:
- Internal clients resolve `*.arsfeld.one` → Storage IP (direct connection, no Cloudflare)
- Cloud services (auth, vault, etc.) still accessible via storage's Caddy catch-all (routes via Tailscale to cloud)
- OR: Cloud services can use explicit overrides if needed (see Option A below)

**Optional: Explicit cloud service routing** (if you want internal clients to use Cloudflare for cloud services):

```nix
customDNS = {
  mapping = {
    # Default: everything to storage
    "*.arsfeld.one" = "100.118.254.137";
  };
  # Block specific cloud services to force public DNS resolution
  # (This makes internal clients use Cloudflare for cloud services)
  customTTL = {
    "auth.arsfeld.one" = "NXDOMAIN";
    "dex.arsfeld.one" = "NXDOMAIN";
    "users.arsfeld.one" = "NXDOMAIN";
    "vault.arsfeld.one" = "NXDOMAIN";
    # ... (13 cloud services)
  };
};
```

**Recommendation**: Start with simple wildcard to storage. Internal clients can access cloud services via Tailscale if needed (cloud.bat-boa.ts.net), or via the Cloudflare route if you add NXDOMAIN blocks.

### Routing Flow Examples

#### Example 1: Jellyfin (Storage Service)
```
1. User requests https://jellyfin.arsfeld.one
2. Cloudflare DNS: jellyfin.arsfeld.one → storage-tunnel-id.cfargotunnel.com
3. Cloudflare edge routes to Storage Tunnel
4. Storage Tunnel forwards to http://localhost:8096 (Storage Caddy)
5. Storage Caddy serves Jellyfin
```

#### Example 2: Authelia (Cloud Service)
```
1. User requests https://auth.arsfeld.one
2. Cloudflare DNS: auth.arsfeld.one → cloud-tunnel-id.cfargotunnel.com
3. Cloudflare edge routes to Cloud Tunnel
4. Cloud Tunnel forwards to http://localhost:9091 (Cloud Caddy)
5. Cloud Caddy serves Authelia
```

#### Example 3: Radarr with Authentication (Storage + Cloud)
```
1. User requests https://radarr.arsfeld.one
2. Cloudflare DNS: radarr.arsfeld.one → storage-tunnel-id.cfargotunnel.com
3. Storage Tunnel → Storage Caddy
4. Storage Caddy checks forward_auth: http://cloud.bat-boa.ts.net:9091 (via Tailscale)
5. Cloud Authelia validates user session
6. If authenticated, Storage Caddy serves Radarr
```

---

## Independent Caddy Configuration

### Current State (Duplicate Configs)

**Problem**: Both cloud and storage run nearly identical Caddy configurations generated from the same `modules/media/gateway.nix`. Cloud proxies to storage, creating unnecessary hop.

```
Cloud Caddy config:
  jellyfin.arsfeld.one → reverse_proxy storage.bat-boa.ts.net:8096
  plex.arsfeld.one → reverse_proxy storage.bat-boa.ts.net:32400
  ...

Storage Caddy config:
  jellyfin.arsfeld.one → reverse_proxy localhost:8096
  plex.arsfeld.one → reverse_proxy localhost:32400
  ...
```

### New State (Independent Configs)

**Goal**: Each host's Caddy only serves its own services. No proxying between hosts.

#### Cloud Caddy Configuration

**What Changes**:
- Remove all storage service virtual hosts from cloud Caddy
- Only configure cloud services (auth, vault, yarr, etc.)
- Simpler configuration, faster reload

**Implementation**:
- `modules/media/gateway.nix` generates configs based on `service.host` attribute
- Cloud host only gets services where `host = "cloud"`
- Automatic cleanup via NixOS evaluation

**Result**:
```nix
# Cloud Caddy only serves:
auth.arsfeld.one → localhost:9091
dex.arsfeld.one → localhost:5556
users.arsfeld.one → localhost:17170
vault.arsfeld.one → localhost:8000
yarr.arsfeld.one → localhost:7070
# ... (13 cloud services only)
```

#### Storage Caddy Configuration

**What Changes**:
- Remove authentication forwarding to external cloud (no longer needed via arsfeld.one)
- Authentication still works via Tailscale for direct access
- Configure all storage services to localhost

**Implementation**:
- Same `modules/media/gateway.nix` generation
- Storage host only gets services where `host = "storage"`
- Automatic cleanup via NixOS evaluation

**Result**:
```nix
# Storage Caddy serves:
jellyfin.arsfeld.one → localhost:8096
plex.arsfeld.one → localhost:32400
overseerr.arsfeld.one → localhost:5055
# ... (70+ storage services)

# Authentication forwarding remains for protected services:
# Uses cloud.bat-boa.ts.net:9091 (Tailscale) for cross-host auth
```

### How Gateway Module Handles This

**Current behavior** (from `modules/media/gateway.nix`):
```nix
# services.caddy.virtualHosts = hosts;
# hosts are generated from cfg.services filtered by current host

hosts = utils.generateHosts {
  services = cfg.services;  # All services (cloud + storage)
  domain = domain;
};
```

**After tunnel deployment**:
- No code changes needed!
- Each host's Caddy config automatically generated from `cfg.services`
- Services already have `host` attribute set (`cloud` or `storage`)
- Gateway module filters services for current host during evaluation
- Result: Each host only gets its own services in Caddy config

**Verification**:
```bash
# On cloud host
systemctl cat caddy | grep "jellyfin.arsfeld.one"  # Should NOT appear

# On storage host
systemctl cat caddy | grep "auth.arsfeld.one"  # Should NOT appear
```

---

## Certificate Management

### Current State

Both hosts independently manage certificates via ACME:
- **Cloud**: Caddy requests `*.arsfeld.one` certificate via Cloudflare DNS-01 challenge
- **Storage**: Caddy requests `*.arsfeld.one` certificate via Cloudflare DNS-01 challenge
- Both use same Cloudflare API credentials from `secrets/cloudflare.age`

**Configuration** (from `modules/media/config.nix`):
```nix
acmeEmail = "alex@arsfeld.one";
dnsProvider = "cloudflare";
# Credentials from config.sops.secrets.cloudflare.path (cloud) or config.age.secrets.cloudflare.path (storage)
```

### New State with Cloudflare Tunnel

**Option 1: Keep ACME on Both Hosts** (Recommended)

**Why**:
- ✅ Already working, no changes needed
- ✅ End-to-end encryption (client → Cloudflare → tunnel → Caddy with Let's Encrypt cert → service)
- ✅ Full control over certificates
- ✅ Works if Cloudflare Tunnel disabled

**How it works**:
```
User → Cloudflare (Cloudflare cert) → Tunnel → Caddy (Let's Encrypt cert) → Service
     └─ TLS termination at edge    └─ TLS termination at origin
```

**Certificate flow**:
1. Caddy on each host requests `*.arsfeld.one` certificate via ACME DNS-01
2. Cloudflare validates DNS challenge
3. Let's Encrypt issues certificate to each host
4. Caddy serves HTTPS on localhost
5. Cloudflare Tunnel forwards HTTPS traffic (or HTTP if configured for Cloudflare-only termination)

**Configuration**: No changes needed!

**Option 2: Cloudflare-Managed Certificates**

**Why consider**:
- ⚠️ Simpler config (no ACME on hosts)
- ⚠️ Cloudflare handles all certificate management
- ⚠️ Backends use HTTP or Cloudflare Origin Certificates

**Why NOT recommended**:
- ❌ Loses end-to-end encryption (Cloudflare can decrypt traffic)
- ❌ Dependency on Cloudflare for all TLS
- ❌ Origin certificates are Cloudflare-specific (not valid outside Cloudflare network)

**Recommendation**: **Option 1** (Keep existing ACME). It already works, provides better security, and requires no changes.

### Certificate Verification

After deployment, verify certificates:

```bash
# Check cloud certificates
ssh cloud "curl https://auth.arsfeld.one -v 2>&1 | grep 'issuer'"
# Should show: issuer: C=US; O=Let's Encrypt; CN=R3

# Check storage certificates
ssh storage "curl https://jellyfin.arsfeld.one -v 2>&1 | grep 'issuer'"
# Should show: issuer: C=US; O=Let's Encrypt; CN=R3
```

---

## Implementation Plan

### Phase 0: Preparation (Week 1, Days 1-7)

**Goal**: Set up Cloudflare Tunnels in dashboard, prepare NixOS configurations

**Tasks**:
1. ✅ Create this architecture plan document
2. ⬜ Create Cloudflare Tunnels in dashboard:
   - Create `cloud-arsfeld` tunnel
   - Create `storage-arsfeld` tunnel
   - Download credentials JSON for both
   - Note tunnel IDs
3. ⬜ Add tunnel credentials to encrypted secrets:
   - Cloud: `nix develop -c sops secrets/sops/cloud-poc.yaml` (add `cloudflare.tunnel-cloud-creds`)
   - Storage: `echo '<json>' | nix develop -c ragenix --rules secrets/secrets.nix -e cloudflare-tunnel-storage-creds.age --editor -`
4. ⬜ Create NixOS modules for Cloudflare Tunnel:
   - `hosts/cloud/services/cloudflare-tunnel.nix` (new file)
   - `hosts/storage/services/cloudflare-tunnel.nix` (new file)
   - Import in respective `configuration.nix` files
5. ⬜ Test build both hosts:
   - `nix build .#nixosConfigurations.cloud.config.system.build.toplevel`
   - `nix build .#nixosConfigurations.storage.config.system.build.toplevel`

**Validation**:
- [ ] Tunnel credentials encrypted and accessible
- [ ] NixOS configurations build successfully
- [ ] No build errors or warnings
- [ ] Git commit: `feat(cloud,storage): add Cloudflare Tunnel configuration`

**Rollback**: Delete files, revert commit. No deployment yet.

### Phase 1: Deploy Cloud Tunnel (Week 2, Days 8-10)

**Goal**: Deploy and test cloud tunnel with cloud services

**Tasks**:
1. ⬜ Deploy cloudflared to cloud host:
   ```bash
   just deploy cloud
   ```
2. ⬜ Verify tunnel connected:
   - Cloudflare Dashboard → Tunnels → `cloud-arsfeld` shows "Healthy"
   - Check logs: `ssh cloud journalctl -u cloudflared -f`
3. ⬜ Create test DNS record (do NOT make active yet):
   - Cloudflare DNS: Create `test-auth.arsfeld.one` CNAME → `<cloud-tunnel-id>.cfargotunnel.com`
   - Enable proxy (orange cloud)
4. ⬜ Test cloud services via tunnel:
   - `curl https://test-auth.arsfeld.one` (should reach Authelia)
   - Test login flow via tunnel
5. ⬜ Verify Tailscale access still works:
   - `curl https://auth.bat-boa.ts.net` (should still work)
   - Ensure tunnel doesn't break existing access

**Validation Checklist**:
- [ ] Cloud tunnel shows "Healthy" in Cloudflare dashboard
- [ ] Test subdomain reaches cloud services correctly
- [ ] Authelia login works via tunnel
- [ ] Tailscale access unaffected
- [ ] Logs show no errors
- [ ] Git commit: `feat(cloud): deploy Cloudflare Tunnel for cloud services`

**Rollback**:
```bash
# Stop cloudflared
ssh cloud systemctl stop cloudflared

# Disable in config
git revert <commit>
just deploy cloud
```

### Phase 2: Deploy Storage Tunnel (Week 2, Days 11-13)

**Goal**: Deploy and test storage tunnel with storage services

**Tasks**:
1. ⬜ Deploy cloudflared to storage host:
   ```bash
   just deploy storage
   ```
2. ⬜ Verify tunnel connected:
   - Cloudflare Dashboard → Tunnels → `storage-arsfeld` shows "Healthy"
   - Check logs: `ssh storage journalctl -u cloudflared -f`
3. ⬜ Create test DNS record:
   - Cloudflare DNS: Create `test-jellyfin.arsfeld.one` CNAME → `<storage-tunnel-id>.cfargotunnel.com`
   - Enable proxy (orange cloud)
4. ⬜ Test storage services via tunnel:
   - `curl https://test-jellyfin.arsfeld.one` (should reach Jellyfin)
   - Test video playback via tunnel
   - Test large file upload (Nextcloud test file)
5. ⬜ Test authentication flow:
   - Access protected service (e.g., Radarr) via tunnel
   - Verify forward_auth to cloud Authelia works via Tailscale

**Validation Checklist**:
- [ ] Storage tunnel shows "Healthy" in Cloudflare dashboard
- [ ] Test subdomain reaches storage services correctly
- [ ] Video streaming works (Jellyfin)
- [ ] File upload works (Nextcloud, <100MB)
- [ ] Authentication works (forward_auth to cloud)
- [ ] Tailscale access unaffected
- [ ] Git commit: `feat(storage): deploy Cloudflare Tunnel for storage services`

**Rollback**:
```bash
# Stop cloudflared
ssh storage systemctl stop cloudflared

# Disable in config
git revert <commit>
just deploy storage
```

### Phase 3: Deploy DNS Automation and Configure Wildcard (Week 2, Days 14-15)

**Goal**: Deploy DNS automation script and configure wildcard DNS

**Tasks**:
1. ⬜ Add Cloudflare API token to secrets:
   ```bash
   nix develop -c sops secrets/sops/cloud-poc.yaml
   # Add: cloudflare.api-token: <your-cloudflare-api-token>
   ```
2. ⬜ Get Cloudflare Zone ID:
   - Cloudflare Dashboard → arsfeld.one domain → Overview → Zone ID (copy)
3. ⬜ Create DNS automation script:
   - Create `hosts/cloud/services/cloudflare-dns-sync.nix`
   - Replace `ZONE_ID_PLACEHOLDER` with actual zone ID
   - Import in `hosts/cloud/configuration.nix`
4. ⬜ Deploy DNS automation to cloud:
   ```bash
   just deploy cloud
   ```
5. ⬜ Trigger DNS sync:
   ```bash
   ssh cloud systemctl start cloudflare-dns-sync
   ssh cloud journalctl -u cloudflare-dns-sync -f
   ```
   - Should create 13 cloud service CNAMEs automatically
6. ⬜ Create wildcard DNS record in Cloudflare:
   - Cloudflare Dashboard → DNS → Add record
   - Type: CNAME
   - Name: *
   - Target: `<storage-tunnel-id>.cfargotunnel.com`
   - Proxy: OFF (gray cloud) initially
7. ⬜ Test resolution:
   ```bash
   dig auth.arsfeld.one  # Should return <cloud-tunnel-id>.cfargotunnel.com
   dig jellyfin.arsfeld.one  # Should return <storage-tunnel-id>.cfargotunnel.com (via wildcard)
   ```
8. ⬜ Update router DNS to simplified wildcard:
   - Edit `hosts/router/services/dns.nix`
   - Change to wildcard: `"*.arsfeld.one" = "100.118.254.137";`
   - Deploy: `just deploy router`

**Validation Checklist**:
- [ ] DNS automation script deployed and running
- [ ] 13 cloud service CNAMEs created automatically
- [ ] Wildcard CNAME created for storage services
- [ ] Router DNS updated to simplified wildcard
- [ ] DNS resolution correct (dig/nslookup)
- [ ] Records in "DNS only" mode (gray cloud) initially
- [ ] Git commit: `feat(cloud): add automated Cloudflare DNS management for cloud services`
- [ ] Git commit: `refactor(router): simplify split-horizon DNS to wildcard rule`

**Rollback**:
- Stop DNS sync: `ssh cloud systemctl stop cloudflare-dns-sync`
- Delete wildcard and cloud CNAMEs in Cloudflare dashboard
- Revert router DNS: `git revert <commit> && just deploy router`

### Phase 4: DNS Cutover (Week 3, Days 16-18)

**Goal**: Enable Cloudflare proxy for all services, routing through tunnels

**Tasks**:
1. ⬜ Enable proxy for cloud services (orange cloud):
   - Cloudflare Dashboard → DNS → Edit each cloud service CNAME
   - Change from "DNS only" to "Proxied"
   - Services: auth, dex, users, vault, yarr, etc. (13 services)
2. ⬜ Test cloud services:
   ```bash
   curl https://auth.arsfeld.one  # Should work via tunnel
   curl https://vault.arsfeld.one  # Should work via tunnel
   ```
3. ⬜ Enable proxy for storage services (orange cloud):
   - Cloudflare Dashboard → DNS → Edit each storage service CNAME
   - Change from "DNS only" to "Proxied"
   - Can batch enable in Cloudflare (select multiple, bulk action)
4. ⬜ Test storage services:
   ```bash
   curl https://jellyfin.arsfeld.one  # Should work via tunnel
   curl https://plex.arsfeld.one  # Should work via tunnel
   curl https://radarr.arsfeld.one  # Should work, auth via cloud
   ```
5. ⬜ Monitor tunnel health:
   - Cloudflare Dashboard → Tunnels → Check both tunnels "Healthy"
   - Monitor for 2-4 hours, check for errors
6. ⬜ Test from multiple locations:
   - External (mobile network): Should work via Cloudflare tunnel
   - Internal (Tailscale/LAN): Should work via direct storage connection (fast)
   - Different devices: Desktop, mobile, tablet

**Validation Checklist**:
- [ ] All 83+ services accessible via `*.arsfeld.one`
- [ ] Both tunnels showing "Healthy"
- [ ] External clients route through Cloudflare
- [ ] Internal clients route directly to storage (verify low latency)
- [ ] Authentication flows work (forward_auth to cloud)
- [ ] Video streaming works (Jellyfin, Plex)
- [ ] File uploads work (Nextcloud, Immich)
- [ ] No 404 or 502 errors
- [ ] Performance excellent for internal (direct), acceptable for external (Cloudflare)
- [ ] Git commit: `feat: complete DNS cutover to hybrid dual-tunnel architecture`

**Rollback**:
```bash
# Disable proxy on all DNS records (back to "DNS only")
# Cloudflare Dashboard → DNS → Bulk action: Set to "DNS only"
# Services revert to test mode within 5-10 minutes
```

### Phase 5: Simplify Caddy Configs (Week 3, Days 19-20)

**Goal**: Clean up Caddy configurations now that proxying between hosts is eliminated

**Tasks**:
1. ⬜ Verify current Caddy configs:
   ```bash
   ssh cloud "systemctl cat caddy | grep arsfeld.one"  # List all cloud virtualHosts
   ssh storage "systemctl cat caddy | grep arsfeld.one"  # List all storage virtualHosts
   ```
2. ⬜ No code changes needed (automatic via gateway module):
   - `modules/media/gateway.nix` already filters by `service.host`
   - Each host only gets its own services in Caddy config
   - Cloud → Storage proxying automatically removed
3. ⬜ Redeploy to ensure clean configs:
   ```bash
   just deploy cloud
   just deploy storage
   ```
4. ⬜ Verify simplified configs:
   ```bash
   # Cloud should NOT have storage services
   ssh cloud "systemctl cat caddy | grep 'jellyfin.arsfeld.one'"  # Should be empty

   # Storage should NOT have cloud services
   ssh storage "systemctl cat caddy | grep 'auth.arsfeld.one'"  # Should be empty
   ```
5. ⬜ Performance test:
   - Measure latency: `curl -w "@curl-format.txt" https://jellyfin.arsfeld.one`
   - Compare to baseline (before tunnel deployment)
   - Expected: 20-50ms added latency (acceptable)

**Validation Checklist**:
- [ ] Cloud Caddy config only contains cloud services
- [ ] Storage Caddy config only contains storage services
- [ ] No proxying between hosts
- [ ] All services still accessible
- [ ] Performance within acceptable range
- [ ] Git commit: `refactor: simplify Caddy configs for independent host operation`

**Rollback**: Not needed (automatic cleanup).

### Phase 6: Monitoring and Stabilization (Week 3-4, Days 21-28)

**Goal**: Monitor for one week to ensure stability before declaring success

**Tasks**:
1. ⬜ Set up tunnel monitoring:
   - Cloudflare Dashboard: Enable email alerts for tunnel disconnections
   - Netdata: Monitor `cloudflared` process CPU/memory usage
2. ⬜ Daily health checks:
   - Both tunnels "Healthy" in dashboard
   - No 502/504 errors in Cloudflare analytics
   - Service logs show no authentication errors
3. ⬜ Test certificate renewal:
   - Wait for next ACME renewal cycle (certs renew ~30 days before expiry)
   - Or force renewal: `ssh cloud systemctl restart caddy` (triggers renewal check)
4. ⬜ Performance monitoring:
   - Track latency over 1 week
   - Monitor for any degradation or spikes
   - Acceptable: <100ms added latency vs direct routing
5. ⬜ User acceptance testing:
   - All services accessible and functional
   - No user-reported issues
   - Authentication flows working correctly

**Validation Checklist**:
- [ ] 7 days uptime with no critical issues
- [ ] Both tunnels stable (no disconnections)
- [ ] Certificate renewals successful
- [ ] Performance acceptable
- [ ] No user complaints
- [ ] Git commit: `docs: update architecture docs to reflect hybrid dual-tunnel production deployment`

**Success Criteria**: All criteria met = hybrid dual-tunnel architecture fully deployed ✅

### Phase 7: Cleanup and Documentation (Week 4, Days 29-35)

**Goal**: Clean up old configs, update documentation, declare mission accomplished

**Tasks**:
1. ⬜ Update documentation:
   - `CLAUDE.md`: Update "Service and Network Details" section
   - `docs/architecture/overview.md`: Document new architecture
   - `README.md`: Update deployment instructions (if applicable)
2. ⬜ Remove old gateway configuration (if any remnants):
   - Verify no more cloud → storage proxying in configs
   - Verify no more split-horizon DNS references
3. ⬜ Archive planning documents:
   - Move `simplification-plan.md` and `dual-tunnel-plan.md` to `docs/architecture/archived/`
   - Keep `hybrid-dual-tunnel-plan.md` as authoritative reference
4. ⬜ Create operational runbook:
   - Document how to add new services
   - Document how to troubleshoot tunnel issues
   - Document rollback procedures
5. ⬜ Celebrate! 🎉
   - Architecture simplified
   - Split-horizon DNS simplified to one wildcard rule
   - Cloud no longer redundant proxy
   - Direct local access maintained (fast internal connections)
   - Automated DNS management (no manual updates for new storage services)
   - Both hosts independent and operational
   - Future consolidation still possible (task-122 compatible)

**Deliverables**:
- [ ] All documentation updated
- [ ] Runbook created: `docs/runbooks/hybrid-dual-tunnel-operations.md`
- [ ] Planning docs archived
- [ ] Git commit: `docs: finalize hybrid dual-tunnel architecture documentation`
- [ ] Close task-124 as complete

---

## Cost Analysis

### Current Architecture Cost

| Item | Cost/Month | Notes |
|------|------------|-------|
| Cloud VPS | $5-10 | Small VPS (1-2 vCPU, 1-2GB RAM) |
| Storage VPS | $20-40 | Larger VPS or home server (media storage) |
| Domains | $1-2 | arsfeld.one annual renewal (rosenfeld.one unused) |
| Cloudflare | $0 | Free plan |
| **Total** | **$26-52** | |

### Hybrid Dual-Tunnel Cost (This Plan)

| Item | Cost/Month | Notes |
|------|------------|-------|
| Cloud VPS | $5-10 | Keep existing VPS |
| Storage VPS | $20-40 | Keep existing VPS |
| Domains | $1-2 | Only arsfeld.one needed (rosenfeld.one optional) |
| Cloudflare | $0 | Free plan supports multiple tunnels |
| Cloudflare Tunnel | $0 | Free (2 tunnels supported on free plan) |
| **Total** | **$26-52** | **No cost change** |

### Task-122 Single-Tunnel Cost (For Comparison)

| Item | Cost/Month | Notes |
|------|------------|-------|
| Cloud VPS | $0 | **Decommissioned** |
| Storage VPS | $20-40 | Keep existing VPS |
| Domains | $1 | Only arsfeld.one needed |
| Cloudflare | $0 | Free plan (1 tunnel) |
| **Total** | **$21-41** | **Save $5-11/month** |

### Task-123 Dual-Tunnel, Dual-Domain Cost (For Comparison)

| Item | Cost/Month | Notes |
|------|------------|-------|
| Cloud VPS | $5-10 | Keep existing VPS |
| Storage VPS | $20-40 | Keep existing VPS |
| Domains | $2-4 | Both arsfeld.one AND rosenfeld.one needed |
| Cloudflare | $0 | Free plan (2 tunnels) |
| **Total** | **$27-54** | **+$1-2 vs hybrid (dual domain cost)** |

### Cost Comparison Summary

- **Hybrid Dual-Tunnel (task-124)**: $26-52/month (no change vs current)
- **Single-Tunnel (task-122)**: $21-41/month (save $5-11/month, ~$60-130/year)
- **Dual-Tunnel Dual-Domain (task-123)**: $27-54/month (+$1-2/month vs hybrid)

### Long-Term Cost Trajectory

**Year 1** (Hybrid dual-tunnel):
- Cost: $312-624/year (same as current)
- Operational: Simplified architecture, no split-horizon DNS
- Flexibility: Can consolidate later

**Year 2+** (Optional consolidation to task-122):
- Cost: $252-492/year (save $60-130/year)
- Operational: Simplest possible (single host)
- Trade-off: Service migration required (4-6 weeks work)

### Non-Monetary Costs

**Operational Overhead**:
- **Current**: High (2 hosts, split-horizon DNS, duplicate configs)
- **Hybrid**: Medium (2 hosts, unified DNS, independent configs)
- **Task-122**: Low (1 host, unified DNS, single config)

**Maintenance Time** (monthly):
- **Current**: ~4 hours (updates, monitoring, troubleshooting 2 hosts)
- **Hybrid**: ~3 hours (updates, monitoring 2 hosts, simpler routing)
- **Task-122**: ~2 hours (updates, monitoring 1 host)

**Time Savings**: Hybrid saves ~1 hour/month vs current, task-122 saves ~2 hours/month vs current.

### Recommendation

**Implement hybrid dual-tunnel now** (task-124):
- ✅ No infrastructure cost change
- ✅ Reduces operational complexity immediately
- ✅ Fast implementation (2-3 weeks)
- ✅ Low risk, easy rollback

**Evaluate consolidation later** (task-122):
- ⏳ After 6-12 months of stable operation
- ⏳ If cloud VPS cost becomes burdensome
- ⏳ If willing to invest 4-6 weeks in service migration
- ⏳ Saves $60-130/year + 1 hour/month maintenance

---

## Comprehensive Comparison of All Approaches

### Architecture Comparison Matrix

| Feature | Current | Task-122 | Task-123 | **Task-124** |
|---------|---------|----------|----------|------------|
| **ROUTING & DNS** ||||
| Split-Horizon DNS | ❌ Yes | ✅ No | ✅ No | ✅ No |
| DNS Complexity | ❌ High | ✅ Low | ⚠️ Medium | ✅ Low |
| Routing Consistency | ❌ No | ✅ Yes | ✅ Yes | ✅ Yes |
| Number of Domains | 1 | 1 | 2 | 1 |
| Subdomain Routing | N/A | Simple | Split by domain | Intelligent |
| **INFRASTRUCTURE** ||||
| Number of Hosts | 2 | 1 | 2 | 2 |
| Cloudflare Tunnels | 0 | 1 | 2 | 2 |
| Caddy Instances | 2 (duplicate) | 1 | 2 (independent) | 2 (independent) |
| Cloud → Storage Proxy | ❌ Yes | N/A | ✅ No | ✅ No |
| Certificate Management | 2 hosts | 1 host | 2 hosts | 2 hosts |
| **DEPLOYMENT** ||||
| Service Migration | N/A | ❌ Required | ✅ Not required | ✅ Not required |
| Implementation Time | N/A | 6 weeks | 2-3 weeks | 2-3 weeks |
| Risk Level | N/A | Medium | Low | Low |
| Rollback Difficulty | N/A | Medium | Easy | Easy |
| Testing Complexity | N/A | High | Low | Low |
| **COST** ||||
| Monthly VPS Cost | $25-50 | $20-40 | $25-50 | $25-50 |
| Monthly Domain Cost | $1-2 | $1 | $2-4 | $1-2 |
| Annual Total | $312-624 | $252-492 | $324-648 | $312-624 |
| vs Current | Baseline | -$60-130 | +$12-24 | $0 |
| **OPERATIONS** ||||
| Operational Complexity | ❌ High | ✅ Low | ⚠️ Medium | ⚠️ Medium-Low |
| Maintenance Time/Month | ~4 hours | ~2 hours | ~3 hours | ~3 hours |
| Debugging Difficulty | ❌ High | ✅ Low | ⚠️ Medium | ✅ Low |
| Monitoring Overhead | ❌ High | ✅ Low | ⚠️ Medium | ⚠️ Medium |
| **FLEXIBILITY** ||||
| Future Consolidation | N/A | N/A | Possible | Possible |
| Service Distribution | Implicit | N/A | Explicit | Explicit |
| Scalability | Limited | Good | Good | Good |
| Cloud Decommission | N/A | Done | Easy | Easy |

### Scoring Summary (Out of 10)

| Criterion | Weight | Current | Task-122 | Task-123 | **Task-124** |
|-----------|--------|---------|----------|----------|------------|
| **Simplicity** | 25% | 3/10 | 10/10 | 7/10 | **8/10** |
| **Implementation Speed** | 20% | N/A | 5/10 | 9/10 | **9/10** |
| **Cost Efficiency** | 15% | 5/10 | 10/10 | 4/10 | **5/10** |
| **Risk Level** | 20% | N/A | 6/10 | 9/10 | **9/10** |
| **Operational Burden** | 20% | 3/10 | 10/10 | 7/10 | **7/10** |
| **Weighted Score** | | **3.5/10** | **8.3/10** | **7.4/10** | **7.8/10** |

### Qualitative Comparison

#### Current Architecture
**Strengths**:
- ✅ Already deployed, no migration needed
- ✅ Both hosts operational

**Weaknesses**:
- ❌ Split-horizon DNS (confusing, hard to debug)
- ❌ Cloud as redundant proxy (unnecessary hop)
- ❌ Duplicate Caddy configurations
- ❌ High operational complexity

**Verdict**: ⚠️ **Needs simplification** - too complex for home lab

---

#### Task-122: Single Tunnel, Storage Only
**Strengths**:
- ✅ Simplest possible architecture
- ✅ Lowest cost ($60-130/year savings)
- ✅ Lowest operational burden (single host)
- ✅ Most efficient (no redundant services)

**Weaknesses**:
- ❌ Requires service migration (6 services from cloud)
- ❌ 6-week implementation (phased migration)
- ❌ Medium risk (authentication stack migration)
- ❌ Cloud host decommissioned (no going back easily)

**Verdict**: ✅ **Best long-term solution**, but requires significant effort upfront

---

#### Task-123: Dual Tunnel, Dual Domain
**Strengths**:
- ✅ No service migration needed
- ✅ Fast implementation (2-3 weeks)
- ✅ Low risk, easy rollback
- ✅ Both hosts remain operational
- ✅ Eliminates split-horizon DNS
- ✅ Eliminates cloud as proxy

**Weaknesses**:
- ❌ Requires two domains (arsfeld.one + rosenfeld.one)
- ❌ Slightly more complex DNS (2 domains to manage)
- ❌ Users must remember which domain for which service
- ❌ +$12-24/year cost vs current

**Verdict**: ⚠️ **Good intermediate solution**, but dual domain is unnecessary complexity

---

#### Task-124: Hybrid Dual Tunnel, Single Domain (THIS PLAN)
**Strengths**:
- ✅ No service migration needed
- ✅ Fast implementation (2-3 weeks)
- ✅ Low risk, easy rollback
- ✅ Both hosts remain operational
- ✅ Eliminates split-horizon DNS
- ✅ Eliminates cloud as proxy
- ✅ Single domain (simpler than task-123)
- ✅ No cost change vs current
- ✅ Can consolidate to task-122 later if desired

**Weaknesses**:
- ⚠️ Higher cost than task-122 ($60-130/year more)
- ⚠️ More operational overhead than task-122 (2 hosts)
- ⚠️ Cloudflare must route subdomains intelligently (small complexity)

**Verdict**: ✅ **Optimal choice for now** - best balance of simplicity, speed, and risk

---

### Decision Framework

**Choose Current**: Never (needs simplification)

**Choose Task-122** (Single Tunnel) IF:
- Willing to invest 6 weeks in service migration
- Want lowest operational cost and complexity
- Don't mind decommissioning cloud host permanently
- Have time and patience for phased migration

**Choose Task-123** (Dual Tunnel, Dual Domain) IF:
- Need fast implementation (2-3 weeks)
- Want to keep both hosts operational
- Don't mind managing two domains
- Okay with slightly higher cost (+$12-24/year)

**Choose Task-124** (Hybrid Dual Tunnel, Single Domain) IF:
- Need fast implementation (2-3 weeks) ✅
- Want to keep both hosts operational ✅
- Prefer single domain simplicity ✅
- Want lowest risk deployment ✅
- Want flexibility to consolidate later ✅
- Don't mind slightly higher cost than task-122 ✅

### Recommendation: Task-124 (This Plan)

**Rationale**:
1. **Fastest time-to-value**: 2-3 weeks vs 6 weeks for task-122
2. **Lowest risk**: No service migration, easy rollback at any phase
3. **Simplest DNS**: Single domain vs dual domain in task-123
4. **Maintains flexibility**: Can consolidate to task-122 later if cloud host becomes unnecessary
5. **No cost change**: Same infrastructure cost as current
6. **Immediate benefits**: Eliminates split-horizon DNS and cloud proxy immediately

**Path Forward**:
1. **Now**: Implement task-124 (2-3 weeks)
2. **6 months**: Evaluate if cloud host truly needed
3. **Later** (optional): Consolidate to task-122 if cloud host is not essential

---

## Migration Path to Single Host (Task-122 Compatibility)

### Why This Matters

The hybrid dual-tunnel architecture (task-124) is designed to be **forward-compatible** with task-122's single-tunnel approach. If you later decide cloud host is not essential, migration to task-122 is straightforward.

### When to Consolidate to Task-122

**Evaluate after 6-12 months of operation**. Consolidate IF:
- ✅ Cloud services are lightly used (low traffic to auth, vault, yarr, etc.)
- ✅ $60-130/year savings is worthwhile
- ✅ Willing to invest 4-6 weeks in service migration
- ✅ Comfortable with single point of failure (storage only)

**Keep hybrid dual-tunnel IF**:
- ✅ Cloud services are heavily used (auth, mqtt, owntracks, etc.)
- ✅ Prefer separation of concerns (auth on cloud, media on storage)
- ✅ Want redundancy (if storage down, auth still works)
- ✅ $5-10/month cloud VPS cost is acceptable

### Migration Steps: Hybrid → Single Tunnel (Task-122)

#### Phase 1: Migrate Cloud Services to Storage (3-4 weeks)

**Services to Migrate** (13 cloud services):
- Authentication: authelia, dex, lldap
- Communication: mosquitto, owntracks, thelounge
- Utilities: vault, yarr, whoogle, metube, invidious, dns, ntfy

**Per-Service Migration Process**:
1. Stop service on cloud
2. Rsync data: `rsync -avz cloud:/var/lib/service storage:/var/lib/service`
3. Move service definition from `cloud` to `storage` in `modules/constellation/services.nix` and `media.nix`
4. Update secrets (add storage to ragenix recipients or sops-nix keys)
5. Deploy to storage: `just deploy storage`
6. Test service on storage
7. Update dependent services (if any)
8. Remove from cloud config

**Migration Order** (lowest to highest risk):
1. Week 1: Utilities (whoogle, metube, yarr, invidious, dns, ntfy)
2. Week 2: Communication (mosquitto, owntracks, thelounge)
3. Week 3: Authentication (dex, lldap, authelia) - highest risk, most dependencies

**Critical**: Authentication stack (authelia, dex, lldap) must be migrated together and tested thoroughly. All storage services depend on authelia for authentication.

#### Phase 2: Update DNS to Point to Storage Tunnel (1 week)

**Tasks**:
1. Update Cloudflare DNS for cloud services:
   - Change `auth.arsfeld.one` CNAME: `<cloud-tunnel-id>.cfargotunnel.com` → `<storage-tunnel-id>.cfargotunnel.com`
   - Repeat for all 13 cloud services
2. Update storage tunnel ingress configuration:
   - Add cloud service routes to `hosts/storage/services/cloudflare-tunnel.nix`
   - Deploy: `just deploy storage`
3. Test all services now routing to storage:
   ```bash
   curl https://auth.arsfeld.one  # Should reach storage
   curl https://vault.arsfeld.one  # Should reach storage
   ```
4. Monitor for 48 hours, ensure no issues

#### Phase 3: Decommission Cloud Tunnel and Host (1 week)

**Tasks**:
1. Stop cloudflared on cloud:
   ```bash
   ssh cloud systemctl stop cloudflared
   ssh cloud systemctl disable cloudflared
   ```
2. Delete cloud tunnel from Cloudflare Dashboard:
   - Zero Trust → Networks → Tunnels → `cloud-arsfeld` → Delete
3. Remove cloud tunnel NixOS configuration:
   ```bash
   git rm hosts/cloud/services/cloudflare-tunnel.nix
   git commit -m "chore(cloud): remove Cloudflare Tunnel (migrated to storage)"
   ```
4. Optional: Decommission cloud host entirely
   - Backup any remaining data
   - Shut down cloud VPS
   - Cancel cloud hosting subscription
   - Remove from Tailscale network
   - Remove from NixOS flake: `nixosConfigurations.cloud`

#### Phase 4: Update Documentation (1 week)

**Tasks**:
1. Update `CLAUDE.md`: Reflect single-host architecture
2. Update `docs/architecture/`: Archive hybrid dual-tunnel plan, create single-tunnel architecture doc
3. Update `modules/constellation/services.nix`: Remove `cloud = {}` section
4. Update `modules/constellation/media.nix`: Remove `cloudServices = {}` section
5. Git commit: `docs: finalize migration to single-tunnel architecture (task-122)`

### Total Migration Time: 4-6 Weeks

**Breakdown**:
- Phase 1: 3-4 weeks (service migration, testing)
- Phase 2: 1 week (DNS updates, monitoring)
- Phase 3: 1 week (cloud decommission)
- Phase 4: 1 week (documentation)

### Final State After Consolidation

**Infrastructure**:
- 1 host: Storage only
- 1 Cloudflare Tunnel: `storage-arsfeld`
- 1 Caddy instance: All 83+ services
- 1 domain: `*.arsfeld.one`

**Cost Savings**:
- $5-10/month cloud VPS eliminated
- $60-120/year savings

**Operational Benefits**:
- Simplest possible architecture
- Lowest maintenance burden (single host)
- Unified service management

**Architecture Diagram**:
```
Internet → Cloudflare (*.arsfeld.one) → Storage Tunnel → Storage Caddy → All Services
Internal → Tailscale → Storage Caddy → All Services
```

---

## Rollback Strategy

### Rollback Triggers

Execute rollback IF:
- ❌ Tunnel disconnection >15 minutes
- ❌ Critical service unavailable >30 minutes
- ❌ Authentication completely broken
- ❌ Performance degradation >50% latency increase
- ❌ Cloudflare outage affecting multiple services
- ❌ User-reported widespread issues

### Rollback Levels

#### Level 1: DNS-Only Rollback (Fastest)

**Use When**: Tunnel issues, Cloudflare outage, routing problems

**Steps**:
1. Disable Cloudflare proxy on all DNS records:
   - Cloudflare Dashboard → DNS → Select all CNAME records
   - Bulk action: Set to "DNS only" (gray cloud)
   - Takes effect in ~5 minutes
2. Re-enable split-horizon DNS on router:
   ```bash
   git revert <commit-hash>  # Restore router DNS overrides
   just deploy router
   ```
3. Verify old routing restored:
   ```bash
   dig jellyfin.arsfeld.one  # Should return storage IP
   curl https://jellyfin.arsfeld.one  # Should work via old path
   ```

**Time**: 5-10 minutes
**Impact**: Minimal - services stay up, just change routing path

**Rollback Complete**: Services accessible via old split-horizon DNS routing

---

#### Level 2: Tunnel Configuration Rollback

**Use When**: Tunnel-specific configuration issues, need to disable tunnels entirely

**Steps**:
1. Execute Level 1 rollback (DNS + router)
2. Stop cloudflared on both hosts:
   ```bash
   ssh cloud systemctl stop cloudflared
   ssh storage systemctl stop cloudflared
   ```
3. Disable cloudflared in NixOS config:
   ```bash
   git revert <commit-hash>  # Revert tunnel configuration commits
   just deploy cloud
   just deploy storage
   ```
4. Verify services accessible via old architecture:
   - External: Via cloud proxy
   - Internal: Via storage direct

**Time**: 15-30 minutes
**Impact**: Low - old architecture fully restored

**Rollback Complete**: Back to original split-horizon architecture

---

#### Level 3: Full Rollback (Complete Reversion)

**Use When**: Need to completely abandon hybrid dual-tunnel approach

**Steps**:
1. Execute Level 2 rollback (DNS + tunnels)
2. Delete Cloudflare Tunnels from dashboard:
   - Zero Trust → Networks → Tunnels → Delete `cloud-arsfeld`
   - Zero Trust → Networks → Tunnels → Delete `storage-arsfeld`
3. Remove all tunnel-related configuration:
   ```bash
   git rm hosts/cloud/services/cloudflare-tunnel.nix
   git rm hosts/storage/services/cloudflare-tunnel.nix
   git rm docs/architecture/hybrid-dual-tunnel-plan.md
   git commit -m "rollback: remove Cloudflare Tunnel implementation"
   ```
4. Remove tunnel credentials from secrets:
   - Cloud: Remove from `secrets/sops/cloud-poc.yaml`
   - Storage: Remove `secrets/cloudflare-tunnel-storage-creds.age`
5. Deploy both hosts:
   ```bash
   just deploy cloud
   just deploy storage
   just deploy router
   ```
6. Delete DNS CNAME records in Cloudflare:
   - Optionally keep DNS records but pointing to cloud public IP
   - Or bulk delete and recreate with old configuration

**Time**: 30-60 minutes
**Impact**: Medium - requires configuration changes, but no data loss

**Rollback Complete**: Fully reverted to original architecture

---

### Rollback Decision Matrix

| Issue Type | Severity | Recommended Rollback | Recovery Time |
|------------|----------|---------------------|---------------|
| Single service down | Low | None (fix service) | <1 hour |
| Tunnel intermittent | Medium | Level 1 (DNS) | 5-10 min |
| Tunnel completely down | High | Level 1 (DNS) | 5-10 min |
| Authentication broken | Critical | Level 1 (DNS) | 5-10 min |
| Performance degradation | Medium | Level 1 (DNS) | 5-10 min |
| Cloudflare outage | High | Level 1 (DNS) | 5-10 min |
| Configuration errors | Medium | Level 2 (Tunnels) | 15-30 min |
| Need to abandon approach | Low | Level 3 (Full) | 30-60 min |

### Rollback Safeguards

**Before Starting Implementation**:
1. Git tag: `git tag pre-hybrid-dual-tunnel`
2. Backup cloud data: `rsync -avz cloud:/var/lib /backup/cloud-$(date +%Y%m%d)`
3. Backup storage data: Snapshot of critical directories
4. Document current state:
   - List of all running services
   - Current DNS configuration (Cloudflare + Blocky)
   - Current Caddy configurations
5. Test rollback procedure in staging (if available)

**During Implementation** (Per Phase):
1. Git commit per phase: Each phase is separate commit with descriptive message
2. Test before proceeding: Each phase must work before next phase
3. Keep old architecture functional: Don't break old routing until cutover phase
4. Monitor continuously: Watch logs, Cloudflare dashboard, Netdata

**Rollback Verification**:
After executing rollback:
1. Test external access: `curl https://jellyfin.arsfeld.one` (via cloud proxy)
2. Test internal access: `curl https://jellyfin.bat-boa.ts.net` (via Tailscale)
3. Test authentication: Login to protected service (e.g., Radarr)
4. Check logs: No errors in Caddy, Authelia, service logs
5. Monitor for 1 hour: Ensure stability before declaring rollback successful

---

## Security Considerations

### Advantages of Hybrid Dual-Tunnel Architecture

#### 1. No Inbound Firewall Rules Required
- ✅ Both tunnels use outbound-only connections to Cloudflare edge
- ✅ No need to expose ports 80/443 on cloud or storage
- ✅ Works behind CGNAT, dynamic IPs, restrictive firewalls
- ✅ Reduced attack surface (no listening ports on public internet)

#### 2. Cloudflare Edge Protection
- ✅ DDoS protection at Cloudflare edge (before reaching hosts)
- ✅ Web Application Firewall (WAF) rules
- ✅ Rate limiting and bot detection
- ✅ TLS termination at edge with Cloudflare certificates
- ✅ Access logs and analytics in Cloudflare dashboard

#### 3. End-to-End Encryption Maintained
```
User → Cloudflare (TLS) → Tunnel (encrypted) → Caddy (TLS) → Service
     └─ Cloudflare cert   └─ Tunnel auth    └─ Let's Encrypt cert
```
- ✅ Traffic encrypted from user to service
- ✅ Cloudflare cannot decrypt (if using Full/Strict TLS mode)
- ✅ Origin certificates validate tunnel connections

#### 4. Authelia Authentication Still Required
- ✅ Authelia forward_auth enforced for protected services
- ✅ Services with built-in auth in `bypassAuth` list (attic, jellyfin, etc.)
- ✅ No services accidentally exposed without authentication
- ✅ Authelia accessible from storage via Tailscale (cloud.bat-boa.ts.net:9091)

#### 5. Tailscale Zero-Trust Network
- ✅ Service-to-service communication uses Tailscale
- ✅ SSH access via Tailscale only (no public SSH)
- ✅ Tailscale ACLs restrict access
- ✅ MagicDNS for internal name resolution

### Security Improvements vs Current Architecture

| Security Aspect | Current | Hybrid Dual-Tunnel | Improvement |
|----------------|---------|-------------------|-------------|
| **Inbound Ports** | 80, 443, 22 (cloud) | None (outbound-only) | ✅ Reduced attack surface |
| **DDoS Protection** | Cloudflare + cloud | Cloudflare edge | ✅ Protected before reaching hosts |
| **Firewall Rules** | Complex (split-horizon) | Simple (Tailscale only) | ✅ Easier to maintain |
| **TLS Termination** | Cloud + Storage | Cloudflare + Storage | ✅ Additional layer at edge |
| **Authentication** | Authelia (cloud) | Authelia (cloud) | ⚠️ Same (no change) |
| **Service Exposure** | Via cloud proxy | Via tunnels | ✅ Explicit per-service routing |

### Security Risks and Mitigations

#### Risk 1: Cloudflare Tunnel Credential Compromise

**Impact**: Attacker with tunnel credentials could route traffic to malicious server

**Mitigation**:
- ✅ Credentials stored in sops-nix/ragenix (encrypted at rest)
- ✅ File permissions: `0440`, owner `cloudflared`
- ✅ No credentials in git repository
- ✅ Rotate tunnel credentials periodically (every 6-12 months)
- ✅ Monitor tunnel usage in Cloudflare dashboard (anomaly detection)
- ✅ Enable Cloudflare Access policies (optional additional layer)

**Detection**:
- Cloudflare dashboard shows unexpected tunnel connections
- Cloudflare analytics show traffic spikes or unusual patterns
- Authelia logs show failed authentication attempts

---

#### Risk 2: Cloudflare Outage or Compromise

**Impact**: If Cloudflare down or compromised, all services inaccessible via `*.arsfeld.one`

**Mitigation**:
- ✅ Tailscale access (`*.bat-boa.ts.net`) unaffected by Cloudflare
- ✅ Can rollback to split-horizon DNS (Level 1 rollback) in <10 minutes
- ✅ Cloudflare has 99.99% uptime SLA and strong security track record
- ✅ Monitor Cloudflare status: https://www.cloudflarestatus.com/

**Contingency Plan**:
1. If Cloudflare outage detected: Execute Level 1 rollback (disable proxy, restore split-horizon)
2. Services accessible within 10 minutes via old routing
3. Re-enable tunnels after Cloudflare recovery

---

#### Risk 3: Single Point of Failure (Per Host)

**Impact**: If storage down, all storage services (jellyfin, plex, etc.) inaccessible

**Mitigation**:
- ✅ Cloud services remain accessible (auth, vault, yarr, etc.)
- ✅ Separation of concerns: authentication on cloud, media on storage
- ✅ Monitor host health: Netdata, Tailscale connectivity
- ✅ Automated alerts on host downtime
- ✅ Backup/restore procedures documented

**Note**: Task-122 (single tunnel, storage only) would have higher risk - if storage down, everything down. Hybrid dual-tunnel maintains some redundancy.

---

#### Risk 4: Man-in-the-Middle at Cloudflare Edge

**Impact**: Cloudflare can theoretically decrypt traffic (man-in-the-middle)

**Mitigation**:
- ✅ Use "Full (Strict)" TLS mode in Cloudflare (validates origin certificates)
- ✅ End-to-end encryption: User → Cloudflare (TLS) → Tunnel → Caddy (TLS) → Service
- ✅ Cloudflare's privacy policy and security track record
- ⚠️ If paranoid: Use Tailscale only (`*.bat-boa.ts.net`) for sensitive services

**Services Recommended for Tailscale-Only** (no Cloudflare):
- Vault (secrets manager) - can use `vault.bat-boa.ts.net` instead
- Authelia admin panel - restrict to Tailscale only
- SSH access - already Tailscale-only

---

### Security Checklist

#### Firewall Configuration
- [ ] Cloud host: Close ports 80, 443 (no longer needed)
- [ ] Cloud host: Keep SSH restricted to Tailscale only
- [ ] Cloud host: Keep Tailscale port 41641/UDP open
- [ ] Storage host: Close ports 80, 443 (no longer needed)
- [ ] Storage host: Keep SSH restricted to Tailscale only
- [ ] Storage host: Keep Tailscale port 41641/UDP open

#### Cloudflare Configuration
- [ ] TLS mode: "Full (Strict)" for arsfeld.one domain
- [ ] WAF rules enabled (Cloudflare dashboard → Security → WAF)
- [ ] Rate limiting enabled (Cloudflare dashboard → Security → Rate Limiting)
- [ ] Bot protection enabled (Cloudflare dashboard → Security → Bots)
- [ ] Analytics and logs enabled (monitor for anomalies)
- [ ] Email alerts enabled (tunnel disconnection, security events)

#### Tunnel Security
- [ ] Tunnel credentials encrypted in sops-nix/ragenix
- [ ] Credentials file permissions: `0440`, owner `cloudflared`
- [ ] No tunnel credentials in git repository
- [ ] Tunnel IDs documented but not committed to public repo
- [ ] Monitor tunnel usage weekly in Cloudflare dashboard

#### Authentication
- [ ] Authelia still required for protected services
- [ ] Services in `bypassAuth` list have their own authentication
- [ ] No services accidentally exposed without authentication
- [ ] Authelia admin panel restricted to Tailscale only
- [ ] Authelia logs monitored for failed authentication attempts
- [ ] Session timeouts configured appropriately

#### Secrets Management
- [ ] All secrets encrypted at rest (sops-nix/ragenix)
- [ ] No secrets in git repository (check with `git secrets --scan`)
- [ ] Secrets file permissions correct (`0440` or `0444`)
- [ ] Rotate secrets periodically (every 6-12 months):
  - [ ] Cloudflare API tokens
  - [ ] Cloudflare Tunnel credentials
  - [ ] Authelia JWT secrets
  - [ ] Service API keys

#### Monitoring
- [ ] Cloudflare tunnel health monitoring (dashboard + email alerts)
- [ ] Netdata monitoring both hosts (CPU, memory, network)
- [ ] Caddy logs monitored for errors (journalctl -u caddy)
- [ ] Authelia logs monitored for auth failures
- [ ] Fail2ban enabled on both hosts (SSH brute force protection)
- [ ] Weekly security audit (check logs, Cloudflare analytics)

---

## Success Criteria

### Technical Success

- [x] Hybrid dual-tunnel architecture plan complete (this document)
- [ ] Both Cloudflare Tunnels deployed and healthy
- [ ] All 83+ services accessible via `*.arsfeld.one`
- [ ] Split-horizon DNS eliminated (router Blocky overrides removed)
- [ ] Cloud → Storage proxying eliminated (independent Caddy configs)
- [ ] Authentication flows working (forward_auth to cloud Authelia)
- [ ] Certificate management working (ACME on both hosts)
- [ ] Performance acceptable (<100ms added latency)
- [ ] 7 days uptime with no critical issues
- [ ] Rollback procedures tested and documented

### Operational Success

- [ ] Documentation updated (CLAUDE.md, architecture docs)
- [ ] Runbook created (operations, troubleshooting)
- [ ] Team trained (or self-documented for future reference)
- [ ] Monitoring configured (Cloudflare alerts, Netdata)
- [ ] Security checklist completed
- [ ] User acceptance testing passed (all services functional)

### Project Success

- [ ] Implementation completed in 2-3 weeks (as planned)
- [ ] No major incidents during deployment
- [ ] No user-reported issues
- [ ] Cost unchanged vs current ($26-52/month)
- [ ] Operational complexity reduced vs current
- [ ] Future consolidation path documented (task-122 compatibility)
- [ ] Task-124 closed as complete

---

## Next Steps

**Awaiting approval of this plan before proceeding with Phase 0 implementation.**

### Questions for Review:

1. ✅ Does the hybrid dual-tunnel approach align with project goals?
2. ✅ Is the 2-3 week implementation timeline acceptable?
3. ✅ Any concerns about using Cloudflare Tunnel for all traffic?
4. ✅ Any specific services that should NOT be routed via Cloudflare? (e.g., vault → Tailscale-only)
5. ✅ Preferred secret management: Continue ragenix for storage, or migrate to sops-nix first (task-120)?

**After approval**: Proceed to Phase 0 (Preparation) and begin tunnel setup.

---

## Appendix: Useful Commands

### Cloudflare Tunnel Management

```bash
# Check tunnel status
ssh cloud journalctl -u cloudflared -f
ssh storage journalctl -u cloudflared -f

# Restart tunnels
ssh cloud systemctl restart cloudflared
ssh storage systemctl restart cloudflared

# Check tunnel config
ssh cloud cat /etc/nixos/configuration.nix | grep cloudflared -A 20
ssh storage cat /etc/nixos/configuration.nix | grep cloudflared -A 20
```

### DNS Testing

```bash
# Check DNS resolution
dig auth.arsfeld.one  # Should return cloud tunnel CNAME
dig jellyfin.arsfeld.one  # Should return storage tunnel CNAME

# Check HTTP routing
curl -I https://auth.arsfeld.one  # Should return 200 or 302
curl -I https://jellyfin.arsfeld.one  # Should return 200

# Check authentication flow
curl https://radarr.arsfeld.one  # Should redirect to Authelia
```

### Performance Testing

```bash
# Latency test
curl -w "@curl-format.txt" -o /dev/null -s https://jellyfin.arsfeld.one

# Where curl-format.txt contains:
#   time_namelookup:  %{time_namelookup}\n
#   time_connect:  %{time_connect}\n
#   time_starttransfer:  %{time_starttransfer}\n
#   time_total:  %{time_total}\n

# Load test (Apache Bench)
ab -n 1000 -c 10 https://jellyfin.arsfeld.one/
```

### Cloudflare Dashboard URLs

- Tunnels: https://one.dash.cloudflare.com/<account-id>/networks/tunnels
- DNS: https://dash.cloudflare.com/<account-id>/arsfeld.one/dns
- Analytics: https://dash.cloudflare.com/<account-id>/arsfeld.one/analytics
- WAF: https://dash.cloudflare.com/<account-id>/arsfeld.one/security/waf

---

**End of Hybrid Dual Cloudflare Tunnel Architecture Plan**
