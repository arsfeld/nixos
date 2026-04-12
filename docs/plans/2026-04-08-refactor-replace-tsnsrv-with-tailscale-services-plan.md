---
title: Replace tsnsrv with native Tailscale Services
type: refactor
status: active
date: 2026-04-08
deepened: 2026-04-08
---

# Replace tsnsrv with native Tailscale Services

## Enhancement Summary

**Deepened on:** 2026-04-08
**Research agents used:** architecture-strategist, security-sentinel, performance-oracle, code-simplicity-reviewer, deployment-verification-agent, pattern-recognition-specialist, best-practices-researcher, framework-docs-researcher

### Key Improvements from Research

1. **BLOCKER DISCOVERED: Funnel does NOT work with `--service` flag.** The `tailscale funnel` CLI has no `--service` flag. ~20 funnel services cannot migrate to native Services. Plan restructured to handle this.
2. **DNS naming confirmed safe:** `svc:jellyfin` resolves as `jellyfin.bat-boa.ts.net` (same as current tsnsrv). No rename sweep needed.
3. **Hairpinning confirmed broken:** Official docs state "Service host devices cannot access the Services they host." Homepage widgets must be rewritten.
4. **Critical bug (Issue #18381):** `set-config` downgrades HTTPS to HTTP when re-importing. Config keys need `svc:` prefix.
5. **Security tradeoffs documented:** Loss of per-service systemd sandboxing (HIGH), identity collapse from per-service to per-host (HIGH). Accepted tradeoffs with mitigations.
6. **Performance gains quantified:** ~750MB-1.5GB memory savings on storage, 15-45s faster boot, 5-15% CPU reduction at idle.
7. **Phases consolidated from 8 to 6** per simplicity review. Dead Caddy-Tailscale code cleanup included.

### New Risks Discovered

- **Funnel incompatibility** changes migration scope fundamentally (see Proposed Solution)
- **`set-config` HTTPS bug** (Issue #18381) may require CLI workaround instead of JSON config
- **Single point of failure**: all services share tailscaled (vs 30 isolated processes)
- **autoApprovers should use host-specific tags**, not generic `tag:service`
- **OAuth key must be revoked** at Tailscale admin console after migration, not just removed from sops

---

## Overview

Replace our custom Go reverse proxy (tsnsrv) with Tailscale's native Services feature (`tailscale serve --service=svc:<name>`) for **non-funnel services**. Funnel services remain on tsnsrv until Tailscale adds `--service` support to `tailscale funnel`.

This eliminates ~10 non-funnel tsnsrv processes immediately. Once funnel support lands, the remaining ~20 can migrate and tsnsrv can be fully removed.

## Problem Statement / Motivation

tsnsrv creates a separate Tailscale node per service via the tsnet library. Each node:
- Runs its own systemd process with dedicated state directory
- Requires an OAuth auth key from sops for ephemeral node registration
- Registers as a tagged-device on the tailnet (currently ~30 nodes)
- Needs periodic cleanup via `scripts/cleanup-tailscale-nodes.sh` due to stale ephemeral nodes
- Requires a rename script (`scripts/rename-tailscale-nodes.sh`) to fix `-1`, `-2` suffix conflicts

Tailscale Services (GA since Jan 2026) provides the same functionality natively through the host's existing `tailscaled` daemon, using TailVIPs instead of separate nodes.

## Proposed Solution

Due to the **funnel incompatibility**, the migration is split into two strategies:

### Strategy A: Non-funnel services → Native Tailscale Services (this plan)

Services without `funnel = true`: auth, vault, www, seafile, bitmagnet, yarr, webdav, gatus, harmonia. These migrate to a new NixOS module wrapping `tailscale serve set-config`.

### Strategy B: Funnel services → Remain on tsnsrv (deferred)

~20 services with `funnel = true` (jellyfin, plex, immich, octoprint, etc.) stay on tsnsrv until Tailscale adds `--service` support to `tailscale funnel`. The tsnsrv module and Go package remain in the repo.

### Alternative: Migrate all, drop Funnel via tsnsrv

If losing Funnel is acceptable (services would only be reachable via tailnet or `*.arsfeld.one` through cloudflared), we could migrate everything immediately. This is a user decision.

## Current Service Inventory

### Non-funnel services (Strategy A — migrate now)

| Service | Host | Port | Source |
|---------|------|------|--------|
| auth | storage | 9091 | hosts/storage/services/auth.nix |
| vault | storage | 8002 | hosts/storage/services/vault.nix |
| www | storage | 8085 | hosts/storage/services/home.nix |
| seafile | storage | 10080 | hosts/storage/services/seafile.nix |
| bitmagnet | storage | 3333 | hosts/storage/services/bitmagnet.nix |
| yarr | storage | 7070 | hosts/storage/services/yarr.nix |
| webdav | storage | 4918 | hosts/storage/services/files.nix:74 |
| gatus | cloud | 8090 | hosts/cloud/services/gatus.nix:139 |
| harmonia | raider | (cache port) | hosts/raider/harmonia.nix:82 |

### Funnel services (Strategy B — deferred, stay on tsnsrv)

| Service | Host | Port | Source |
|---------|------|------|--------|
| jellyfin | storage | 8096 | modules/services/media-streaming.nix |
| plex | storage | 32400 | modules/services/media-streaming.nix |
| stash | storage | 9999 | modules/services/media-streaming.nix |
| audiobookshelf | storage | 13378 | modules/services/home-apps.nix |
| grocy | storage | 9283 | modules/services/home-apps.nix |
| immich | storage | 15777 | hosts/storage/services/immich.nix |
| hass | storage | 8123 | modules/constellation/home-assistant.nix |
| opencloud | storage | 9200 | modules/constellation/opencloud.nix |
| netdata | storage | 19999 | hosts/storage/services/infra.nix |
| grafana | storage | 3010 | hosts/storage/services/infra.nix |
| home | storage | 8085 | hosts/storage/services/home.nix |
| n8n | storage | 5678 | hosts/storage/services/ai.nix |
| code | storage | 4444 | hosts/storage/services/develop.nix |
| forgejo | storage | 3001 | hosts/storage/services/develop.nix |
| syncthing | storage | 8384 | hosts/storage/services/files.nix |
| filebrowser | storage | 38080 | hosts/storage/services/files.nix |
| romm | storage | 8998 | hosts/storage/services/misc.nix |
| speedtest | storage | 8765 | hosts/storage/services/misc.nix |
| filestash | storage | 8334 | hosts/storage/services/misc.nix |
| octoprint | octopi | 5000 | hosts/octopi/configuration.nix:33 |
| octoprint | raspi3 | 5000 | hosts/raspi3/configuration.nix:33 |

### Auth pattern summary

No tsnsrv service uses forward auth (Authelia). The gateway's `generateTsnsrvService` in `modules/media/__utils.nix:184` explicitly skips auth: "No Authelia for bat-boa.ts.net - Tailscale provides network-level authentication." Authelia only applies at the Caddy layer for `*.arsfeld.one` access.

## Resolved Unknowns

### U1: DNS naming — RESOLVED (safe)

**Answer:** `svc:jellyfin` resolves as `jellyfin.bat-boa.ts.net`. The `svc:` prefix is only used in CLI/ACL — it does NOT appear in the DNS name. Confirmed by official Tailscale documentation.

**Impact:** No codebase rename sweep needed. All `*.bat-boa.ts.net` references remain valid.

**Still verify in Phase 0** with a live test on raider to be 100% certain for our tailnet.

### U2: Funnel — RESOLVED (not supported)

**Answer:** `tailscale funnel` CLI does **NOT** have a `--service` flag. There is no `funnel` field in the JSON config format. The Tailscale beta blog says services "can hook up to Funnels" but no mechanism exists in the current CLI or config format.

**Impact:** ~20 funnel services CANNOT migrate. Plan restructured — see Proposed Solution above.

**Open GitHub issues:** #18381 (set-config HTTPS bug), #18255 (services not advertised by default), #18219 (TLS termination with services).

### U3: API pre-registration — RESOLVED (available)

**Answer:** API endpoint exists at `POST /api/v2/tailnet/-/services`. Admin console also works. Services can also be implicitly created when a host first advertises with `tailscale serve --service=svc:name` (shows as "Pending" → auto-approved if `autoApprovers` configured).

**Impact:** Low friction. Use admin console for initial setup, auto-approval for ongoing.

### U4: Hairpinning — RESOLVED (broken, as expected)

**Answer:** Official docs confirm: "Service host devices cannot access the Services they host." This is a hard limitation of TailVIPs.

**Impact:** Homepage widgets on storage that make server-side API calls to `*.bat-boa.ts.net` for co-located services will break. Mitigation: rewrite widget URLs to `http://127.0.0.1:<port>`.

**Affected files:**
- `hosts/storage/services/homepage.nix:18-54` — widget URLs for tautulli, transmission, radarr, sonarr, lidarr
- `modules/services/media-apps.nix:31` — Ohdio CHECK_ORIGIN

## Technical Considerations

### Cross-host dependencies

- **Cloud → storage auth**: Cloud's Caddy uses `auth.bat-boa.ts.net:443` for Authelia forward auth (`hosts/cloud/configuration.nix:73`). Auth runs on storage, so this is cross-host (NOT hairpinning). DNS name stays the same (U1 resolved). **No change needed.**
- **Cloud → storage dex/LLDAP**: Uses `storage.bat-boa.ts.net:36958` and `:64459` — these go to the host's Tailscale IP directly, not through tsnsrv. Unaffected.
- **Backup targets**: `storage.bat-boa.ts.net:8000` in `modules/constellation/backup.nix:87` — host IP, not tsnsrv. Unaffected.

### Security considerations

**Accepted tradeoffs (from security review):**

| Finding | Severity | Decision |
|---------|----------|----------|
| Loss of per-service systemd sandboxing (DynamicUser, PrivateDevices, etc.) | HIGH | Accepted — tailscaled is a well-maintained single daemon vs 30 custom Go processes. Lower total attack surface. |
| Identity collapse from per-service (`tag:service` nodes) to per-host | HIGH | Accepted — tighten host-level ACLs to compensate. Review Tailscale ACL policy. |
| autoApprovers with generic `tag:service` allows any tagged device to claim service names | MEDIUM | Use host-specific tags: `"svc:auth": ["tag:storage"]`, `"svc:gatus": ["tag:cloud"]` |
| Stale OAuth key persists post-migration | MEDIUM | Phase 5: revoke OAuth client credential at Tailscale admin console |
| Funnel misconfiguration could expose non-funnel services publicly | MEDIUM | N/A for Strategy A (no funnel services migrate). Relevant for future Strategy B. |
| Localhost fallback removes TLS for hairpinning workaround | LOW | Acceptable — server-side calls on same machine don't need TLS |

**Action items:**
- Use host-specific tags in `autoApprovers.services` (not generic `tag:service`)
- Revoke tsnsrv OAuth credential at Tailscale admin console in Phase 5 cleanup
- Verify `tailscale-key` sops secret usage in Phase 0 (before migration, not deferred)

### What we lose (acceptable)

- **Per-service Prometheus metrics**: No Grafana dashboards or alerts currently consume them. tailscaled exposes node-level metrics at `http://100.100.100.100/metrics`.
- **WhoIs identity headers**: No service reads `X-Tailscale-User-*` headers.
- **Per-service process isolation**: Mitigated by tailscaled being well-maintained.
- **OCI sidecar support**: Not used. Dropping.

### What we gain

- **~750MB-1.5GB memory savings on storage** (30 Go runtimes × 30-60MB each → 0 extra processes)
- **15-45s faster boot/deploy** (no OAuth token exchange + node registration × 30)
- **5-15% CPU reduction at idle** (eliminating 30 Go GC cycles, 30 WireGuard tunnels, 30 DERP connections)
- **Zero stale ephemeral nodes** — no cleanup/rename scripts needed
- **TailVIP stability** — service IP decoupled from host, enabling future HA/migration

### Known bug: set-config HTTPS downgrade (Issue #18381)

`tailscale serve set-config` infers protocol from the target URL scheme. `http://localhost:8096` registers as HTTP even if you want HTTPS termination. Workaround: use imperative CLI commands (`tailscale serve --service=svc:name --https=443 http://localhost:port`) instead of `set-config` for HTTPS services.

**Impact on module design:** The oneshot may need to use individual `tailscale serve` CLI commands per service instead of a single `set-config` call. Verify this bug still exists in Phase 0.

### Systemd ordering

The new `tailscale serve set-config` oneshot must run after:
1. `tailscaled.service` (daemon is running)
2. `tailscaled-autoconnect.service` (host is authenticated — verify this unit exists on each host)
3. Network is online

**Research insight:** Add `restartTriggers = [ configJson ]` so the oneshot re-runs on `nixos-rebuild switch` when config changes. Without this, changes only apply on reboot.

**Research insight:** Add `ExecStartPre` that polls `tailscale status --json` until the node is connected, since `tailscaled.service` starting doesn't guarantee authentication is complete.

## System-Wide Impact

### Single point of failure tradeoff

Currently, if one tsnsrv service crashes, the other ~29 continue. With native Services, all services go through `tailscaled`. If `tailscaled` restarts, ALL services are briefly unavailable. This is an accepted tradeoff — `tailscaled` is far more stable than 30 custom Go processes, and `*.arsfeld.one` access via cloudflared is completely independent.

### CI/CD during migration

The gateway module change and host migrations must be coordinated to keep CI green. Two approaches:

**Option A (recommended): Dual-write transition.** Have `__utils.nix` generate configs for BOTH `services.tsnsrv.services` and `services.tailscale-serve.services`, controlled by a per-host flag (`media.gateway.useTailscaleServe`). Hosts opt in individually.

**Option B: Atomic commit.** Merge module + gateway + all host changes in one commit. Simpler but riskier — all hosts must build.

### Hosts with no tsnsrv: cottage, router, r2s, g14

These hosts have no tsnsrv services and need no migration. Verify builds pass after module changes.

## Implementation Phases

### Phase 0: Verify and Prepare

**Goal:** Live-test all assumptions on raider (lowest risk). Set up ACL policy.

**Tasks:**
- [ ] Verify `tailscale-key` sops secret usage — is it used by anything besides tsnsrv? (`grep -r "tailscale-key" --include="*.nix" . | grep -v tsnsrv`)
- [ ] Test DNS naming: `tailscale serve --service=svc:test --https=443 127.0.0.1:8080` on raider
- [ ] Verify DNS resolves as `test.bat-boa.ts.net` (not `svc-test`)
- [ ] Test hairpinning: from raider, `curl https://test.bat-boa.ts.net` (expect failure)
- [ ] Test `set-config` JSON format — apply minimal config, verify with `tailscale serve status --json`
- [ ] Test Issue #18381: does `set-config` downgrade HTTPS? If so, plan CLI workaround
- [ ] Verify `tailscaled-autoconnect.service` exists: `systemctl list-units 'tailscale*'` on each host
- [ ] Confirm funnel limitation: `tailscale funnel --help | grep service` (expect no match)
- [ ] Add `autoApprovers.services` to Tailscale ACL policy with **host-specific tags**:
  ```json
  "autoApprovers": {
    "services": {
      "svc:auth": ["tag:storage"],
      "svc:vault": ["tag:storage"],
      "svc:webdav": ["tag:storage"],
      "svc:gatus": ["tag:cloud"],
      "svc:harmonia": ["tag:raider"]
    }
  }
  ```
- [ ] Create service definitions for all non-funnel services via admin console or API
- [ ] Clean up test: `tailscale serve clear svc:test`
- [ ] Document findings, update this plan

**Decision gate:** If `set-config` HTTPS bug is confirmed, switch module design to per-service CLI commands.

### Phase 1: Write Module + Update Gateway

**Goal:** Single atomic phase — module and gateway integration together (they can't exist independently).

**New module** (`modules/tailscale-serve.nix`):

```nix
{ config, lib, pkgs, ... }:
let
  cfg = config.services.tailscale-serve;
  configJson = builtins.toJSON {
    version = "0.0.1";
    services = lib.mapAttrs' (name: svc: {
      name = "svc:${name}";
      value = {
        endpoints = {
          "tcp:443" = "http://localhost:${toString svc.port}";
        };
      };
    }) cfg.services;
  };
in {
  options.services.tailscale-serve = {
    enable = lib.mkEnableOption "native Tailscale Services via tailscale serve";
    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          port = lib.mkOption { type = lib.types.port; };
        };
      });
      default = {};
    };
  };

  config = lib.mkIf (cfg.enable && cfg.services != {}) {
    environment.etc."tailscale/serve-config.json".text = configJson;

    systemd.services.tailscale-serve-config = {
      description = "Apply Tailscale Services configuration";
      after = [ "tailscaled.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ configJson ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Wait for tailscale to be fully connected before applying config
        ExecStartPre = "${pkgs.bash}/bin/bash -c 'until ${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -e .Self.Online; do sleep 1; done'";
        ExecStart = "${pkgs.tailscale}/bin/tailscale serve set-config /etc/tailscale/serve-config.json --all --yes";
      };
    };
  };
}
```

**Design decisions (from research):**
- **`services.tailscale-serve`** namespace (not `tailscale-services`) — avoids triple "services" nesting, maps directly to `tailscale serve` command
- **No `protocol` option** — YAGNI. Every service uses `http://localhost`. Add if needed later.
- **No `funnel` option** — funnel doesn't work with `--service` flag. Funnel services stay on tsnsrv.
- **`restartTriggers = [ configJson ]`** — re-applies config on `nixos-rebuild switch` when services change
- **`ExecStartPre` polls for tailscale online** — ensures tailscaled is authenticated before applying config
- **`environment.etc` over `pkgs.writeText`** — debuggable (`cat /etc/tailscale/serve-config.json`), matches `network-metrics-exporter` pattern in repo
- **Config keys use `svc:${name}` prefix** — required by Tailscale Services JSON format

**Gateway integration changes:**

Update `modules/media/__utils.nix` to add `generateTailscaleServeService` alongside existing `generateTsnsrvService`:

```nix
# New function — generates config for services.tailscale-serve
generateTailscaleServeService = {cfg}:
  optionalAttrs (config.networking.hostName == cfg.host
    && cfg.exposeViaTailscale
    && !cfg.settings.funnel)  # Only non-funnel services
  {
    "${cfg.name}" = { port = cfg.port; };
  };
```

Update `modules/media/gateway.nix:198` to write to **both** modules:

```nix
# Non-funnel services → native Tailscale Services
services.tailscale-serve.services = utils.generateTailscaleServeConfigs {
  services = cfg.services;
};

# Funnel services → tsnsrv (until funnel supports --service)
services.tsnsrv.services = utils.generateTsnsrvConfigs {
  services = cfg.services;
};
```

Update `generateTsnsrvService` to **only** produce configs for funnel services:

```nix
generateTsnsrvService = {cfg}:
  optionalAttrs (config.networking.hostName == cfg.host
    && cfg.exposeViaTailscale
    && cfg.settings.funnel)  # Only funnel services
  {
    "${cfg.name}" = {
      toURL = "http://127.0.0.1:${toString cfg.port}";
      funnel = true;
    };
  };
```

**Also clean up dead code:**
- [ ] Delete `generateTailscaleNodes` function in `__utils.nix` (lines 69-82, dead Caddy-Tailscale code)
- [ ] Delete `isBoundToTailscale` branches in `__utils.nix` (lines 94-96, 113-121)
- [ ] Delete `media.gateway.tailscale.*` options in `gateway.nix` (lines 149-189, disabled since task-48)

**Build verification (all hosts must pass):**
```bash
for host in storage cloud raider octopi raspi3 router r2s g14 cottage; do
  nix build ".#nixosConfigurations.$host.config.system.build.toplevel"
done
```

### Phase 2: Migrate Low-Risk Hosts (raider, then cloud)

**Goal:** Validate on hosts with only non-funnel services.

#### Raider (harmonia — non-funnel)

- [ ] Add `services.tailscale-serve.enable = true` to raider config
- [ ] Remove tsnsrv defaults block from `hosts/raider/harmonia.nix:82-91` (harmonia will come through gateway)
- [ ] Build and deploy: `just deploy raider`
- [ ] Verify: `curl -s https://harmonia.bat-boa.ts.net/nix-cache-info` returns valid response
- [ ] Verify: `ssh raider "tailscale serve status --json"` shows harmonia service
- [ ] Run cleanup: `./scripts/cleanup-tailscale-nodes.sh`

#### Cloud (gatus — non-funnel)

- [ ] Add `services.tailscale-serve.enable = true` to cloud config
- [ ] Replace `services.tsnsrv.services.gatus` in `hosts/cloud/services/gatus.nix` with `services.tailscale-serve.services.gatus = { port = 8090; }`
- [ ] Remove tsnsrv defaults from `hosts/cloud/services.nix` **only if** no funnel services on cloud (cloud has none — safe)
- [ ] Build and deploy: `just deploy cloud`
- [ ] Verify: `curl -s https://gatus.bat-boa.ts.net` returns 200
- [ ] Verify cross-host auth: `ssh cloud "curl -s https://auth.bat-boa.ts.net/api/health"` returns 200
- [ ] Verify `*.arsfeld.dev` services still work

### Phase 3: Migrate Storage Non-Funnel Services

**Goal:** Migrate ~7 non-funnel gateway services + webdav. Funnel services remain on tsnsrv.

**Pre-migration:**
- [ ] Fix hairpinning: rewrite homepage widget URLs to `http://127.0.0.1:<port>` for co-located services
- [ ] Run cleanup: `./scripts/cleanup-tailscale-nodes.sh`

**Migration:**
- [ ] Add `services.tailscale-serve.enable = true` to storage config
- [ ] Replace `services.tsnsrv.services.webdav` in `hosts/storage/services/files.nix` with `services.tailscale-serve.services.webdav = { port = 4918; }`
- [ ] Gateway integration (Phase 1) handles splitting funnel/non-funnel automatically
- [ ] **Keep** `services.tsnsrv` block in `hosts/storage/services/misc.nix` — still needed for funnel services
- [ ] Build and deploy: `just deploy storage`
- [ ] Verify non-funnel services: auth, vault, www, seafile, bitmagnet, yarr, webdav
- [ ] Verify funnel services still work via tsnsrv: jellyfin, plex, immich, etc.
- [ ] Verify homepage widgets (hairpinning mitigation)
- [ ] Verify cross-host auth from cloud still works

**Smoke tests:**
```bash
# Non-funnel (should be on native Services)
for svc in auth vault seafile bitmagnet yarr webdav; do
  echo -n "$svc: "; curl -s -o /dev/null -w "%{http_code}" "https://$svc.bat-boa.ts.net"; echo
done

# Funnel (should still be on tsnsrv)
for svc in jellyfin plex immich grafana home; do
  echo -n "$svc: "; curl -s -o /dev/null -w "%{http_code}" "https://$svc.bat-boa.ts.net"; echo
done

# Cross-host auth
ssh cloud "curl -s -o /dev/null -w '%{http_code}' https://auth.bat-boa.ts.net/api/health"
```

### Phase 4: Partial Cleanup

**Goal:** Remove what we can. tsnsrv module and package stay for funnel services.

- [ ] Delete `scripts/cleanup-tailscale-nodes.sh` (non-funnel services no longer create ephemeral nodes; funnel services still do but cleanup is less critical with fewer nodes)
- [ ] Delete `scripts/rename-tailscale-nodes.sh`
- [ ] Clean `/var/lib/tsnsrv-*` state dirs for migrated services
- [ ] Remove dead code from `__utils.nix` and `gateway.nix` (Caddy-Tailscale remnants)
- [ ] Revoke tsnsrv OAuth client credential at Tailscale admin console if no longer needed (check if funnel services still use it — they do, so only revoke if a separate key is created)
- [ ] Update docs: `docs/tailscale-cleanup-setup.md`, architecture docs
- [ ] Final build verification for all hosts

### Phase 5 (Future): Migrate Funnel Services

**Blocked on:** Tailscale adding `--service` support to `tailscale funnel` (or a `funnel` field in the `set-config` JSON).

**When this is available:**
- [ ] Move all funnel services from tsnsrv to tailscale-serve module (add funnel option)
- [ ] Migrate octopi and raspi3 (octoprint with funnel)
- [ ] Remove tsnsrv entirely: delete `packages/tsnsrv/`, `modules/tsnsrv.nix`
- [ ] Remove `tailscale-key` sops secret from all hosts (after verifying no other consumers)
- [ ] Revoke OAuth credential at Tailscale admin console

## Rollback Strategy

- **Per-host rollback:** Each host can be independently reverted by restoring its tsnsrv config and redeploying. `modules/tsnsrv.nix` and `packages/tsnsrv/` remain in the repo throughout.
- **Gateway dual-write:** Both modules coexist. The gateway splits services by funnel flag. Reverting a host to tsnsrv-only just means re-enabling tsnsrv for non-funnel services on that host.
- **DNS conflict prevention:** Run cleanup script before each host migration. Old ephemeral nodes expire within 5 minutes.
- **ACL rollback:** `autoApprovers.services` entries are additive — they don't affect existing tsnsrv nodes. Can be removed without impact.
- **Blast radius:** A failed deploy only affects the deployed host. Caddy-based `*.arsfeld.one` access is completely independent.

## Acceptance Criteria

- [ ] All non-funnel services accessible via `*.bat-boa.ts.net` through native Tailscale Services
- [ ] All funnel services still accessible via `*.bat-boa.ts.net` through tsnsrv
- [ ] Cloud's Authelia forward auth working cross-host
- [ ] Homepage widgets functional on storage (hairpinning mitigated)
- [ ] No duplicate tsnsrv processes for migrated services
- [ ] All hosts build cleanly
- [ ] Dead Caddy-Tailscale code removed from gateway

## Success Metrics

- **Process reduction:** ~30 tsnsrv services → ~20 (funnel only). ~10 non-funnel processes eliminated.
- **Tailnet node reduction:** ~30 tagged-devices → ~20. ~10 fewer ephemeral nodes.
- **Memory savings:** ~300-600MB on storage (10 fewer Go processes × 30-60MB each)
- **Boot time improvement:** ~5-15s faster (10 fewer OAuth + registration sequences)
- **Code added:** ~50-line module
- **Dead code removed:** ~65 lines (Caddy-Tailscale remnants in gateway)
- **Full cleanup (Phase 5):** Additional ~20 processes, 855-line module deletion, Go package deletion

## Dependencies & Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Funnel never gets --service support | Low | Medium | Services remain on tsnsrv indefinitely; it works fine |
| set-config HTTPS bug (#18381) | High | Medium | Use per-service CLI commands instead of JSON config |
| Hairpinning breaks homepage | Confirmed | Medium | Rewrite widget URLs to localhost in Phase 3 |
| Stale nodes cause DNS conflicts | Medium | Low | Run cleanup script before each host migration |
| Single tailscaled failure takes all services down | Low | Medium | *.arsfeld.one path is independent; tailscaled is highly stable |
| autoApprovers too permissive | Medium | Medium | Use host-specific tags, not generic tag:service |
| CI breaks during migration | Medium | Low | Dual-write gateway approach keeps both module paths active |

## Deployment Verification Checklist

### Per-host minimum smoke tests

| Host | Test | Command | Expected |
|------|------|---------|----------|
| raider | Harmonia cache info | `curl -s https://harmonia.bat-boa.ts.net/nix-cache-info` | Contains `StoreDir` |
| cloud | Gatus + auth chain | `curl -s -o /dev/null -w "%{http_code}" https://gatus.bat-boa.ts.net && curl -s -o /dev/null -w "%{http_code}" https://planka.arsfeld.dev` | 200 + 302 |
| storage | Auth health + funnel check | `curl -s -o /dev/null -w "%{http_code}" https://auth.bat-boa.ts.net/api/health && curl -s -o /dev/null -w "%{http_code}" https://jellyfin.bat-boa.ts.net` | 200 + 200 |

### Post-deploy monitoring (first 24 hours per phase)

- +5 min: Smoke tests above
- +15 min: Full service sweep (`for svc in ...; curl ...`)
- +1 hour: Cross-host auth + homepage widgets
- +4 hours: Gatus dashboard review (all green?)
- +24 hours: Final review, proceed to next phase

### Rollback commands

```bash
# Per-host rollback
git checkout HEAD~1 -- hosts/<host>/...
just deploy <host>

# Verify tsnsrv services come back
ssh <host> "systemctl list-units 'tsnsrv*'"
```

## Sources & References

### Internal References
- `modules/tsnsrv.nix` — current NixOS module (stays for funnel services)
- `modules/media/__utils.nix:179-196` — gateway tsnsrv config generation
- `modules/media/gateway.nix:198` — gateway consuming tsnsrv configs
- `packages/tsnsrv/src/` — custom Go package (stays for funnel services)
- `docs/cloudflared-migration-analysis.md` — previous architecture analysis
- `docs/tailscale-cleanup-setup.md` — ephemeral node cleanup procedures

### External References
- Tailscale Services docs: https://tailscale.com/docs/features/tailscale-services
- Tailscale Services config file: https://tailscale.com/kb/1589/tailscale-services-configuration-file
- `tailscale serve` CLI reference: https://tailscale.com/docs/reference/tailscale-cli/serve
- Issue #18381 (set-config HTTPS bug): https://github.com/tailscale/tailscale/issues/18381
- Issue #18255 (services not advertised): https://github.com/tailscale/tailscale/issues/18255
- Issue #18219 (TLS termination): https://github.com/tailscale/tailscale/issues/18219
- Tailscale API: `api.tailscale.com/api/v2/tailnet/-/services`
- Auto-approval: `autoApprovers.services` in ACL policy
- Tailscale client metrics: https://tailscale.com/kb/1482/client-metrics

### Pre-existing issue found during security review
- `hosts/storage/services/misc.nix:84` — hardcoded `APP_KEY` for speedtest-tracker should be moved to sops (unrelated to this migration)
