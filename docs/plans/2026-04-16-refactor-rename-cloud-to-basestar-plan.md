---
title: "Rename host cloud to basestar"
type: refactor
status: active
date: 2026-04-16
---

# Rename host cloud to basestar

## Overview

Rename the NixOS host `cloud` to `basestar` as the next step of the BSG hostname scheme defined in `docs/bsg-hostnames.md`. Basestar is the Cylon capital ship -- "Different architecture (aarch64 vs x86 = Cylon vs Colonial), remote, public-facing."

This is a mechanical rename touching ~30 functional files plus documentation. No behavior changes, no architectural changes. The `*.arsfeld.dev` domains are unchanged -- only the host identity and Tailscale node name change.

## Problem Statement / Motivation

The BSG hostname scheme standardizes machine names around Battlestar Galactica ships. `cottage` → `pegasus` is already completed. `cloud` → `basestar` is next because it's a single-purpose server with straightforward services, making it a good candidate before tackling `storage` → `galactica` (the most complex host).

## Proposed Solution

Single atomic commit with all Nix source changes, coordinated with an external Tailscale node rename. More cross-host references than the pegasus rename due to cloud's role as an aarch64 remote builder.

## Technical Considerations

### sops defaultSopsFile path

`modules/constellation/sops.nix` sets `defaultSopsFile = "${self}/secrets/sops/${hostname}.yaml"` when `constellation.sops.enable = true`. After rename, this resolves to `secrets/sops/basestar.yaml`. The file must exist. Rename `secrets/sops/cloud.yaml` to `secrets/sops/basestar.yaml` using `git mv` -- the encrypted content and age recipients stay identical.

### sops secret key names inside the file

Keys like `restic-rest-cloud` inside `secrets/sops/cloud.yaml` do NOT need renaming. They're just YAML keys referenced by `sops.secrets."restic-rest-cloud"` in Nix. Renaming them would require decrypt/edit/re-encrypt for no functional benefit. Leave as-is.

### Tailscale MagicDNS ordering

Colmena derives `targetHost = "${hostName}.bat-boa.ts.net"` dynamically. After directory rename, `just deploy basestar` connects to `basestar.bat-boa.ts.net`. This DNS name must exist **before** attempting deployment. The Tailscale node rename is external and must happen first.

### Remote builder references

Cloud is the aarch64 remote builder for all other hosts. References exist in:
- `modules/constellation/common.nix:59` -- exclusion conditional (`hostName != "cloud"`)
- `modules/constellation/common.nix:61` -- builder hostname (`cloud.bat-boa.ts.net`)
- `modules/constellation/common.nix:102` -- SSH known hosts
- `nix-builders.conf:8-9` -- builder connection string
- `home/home.nix:152` -- home-manager exclusion conditional
- `flake-modules/deploy.nix:15` -- remote build conditional

All six must update atomically. If any are missed, builds will fail on every non-basestar host.

### Restic backup repository path

`hosts/cloud/backup.nix:30` references `rest:https://restic.arsfeld.one/cloud`. After rename, this should become `rest:https://restic.arsfeld.one/basestar`. The restic REST server on storage needs the path renamed on disk before the next backup fires:

```bash
ssh storage.bat-boa.ts.net sudo mv /var/data/restic-data/cloud /var/data/restic-data/basestar
```

Alternatively, keep the old path (backup data doesn't care about hostname) -- but rename for consistency.

### CI/CD build matrix

`.github/workflows/build.yml:24` has `host: cloud` in the matrix. After rename, CI will attempt `nix build .#nixosConfigurations.basestar...` which is correct. But the CI run immediately after the commit will reference the new name, so this must be in the same commit.

### arsfeld.dev domains unchanged

Services like `blog.arsfeld.dev`, `plausible.arsfeld.dev`, etc. are domain-based, not hostname-based. They don't change. The Caddy config, ACME certs, and DNS records all stay the same.

## Acceptance Criteria

- [x] `nix build .#nixosConfigurations.basestar.config.system.build.toplevel` succeeds
- [x] `nix build .#nixosConfigurations.storage.config.system.build.toplevel` succeeds
- [x] `nix build .#nixosConfigurations.raider.config.system.build.toplevel` succeeds (remote builder ref)
- [x] `grep -r '"cloud"' hosts/ modules/ .sops.yaml flake-modules/ home/ nix-builders.conf` returns zero hostname matches
- [x] `basestar.bat-boa.ts.net` resolves via Tailscale MagicDNS
- [ ] `just deploy basestar` succeeds; `hostnamectl` on target shows `basestar`
- [ ] `just deploy storage` succeeds
- [ ] `blog.arsfeld.dev`, `plausible.arsfeld.dev`, `planka.arsfeld.dev`, `siyuan.arsfeld.dev` all accessible
- [ ] CI build workflow passes for basestar

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Tailscale rename not propagated before deploy | Verify with `ping basestar.bat-boa.ts.net` before deploying |
| Remote builder breaks on all hosts | Deploy basestar first (it doesn't use remote builders), then redeploy other hosts |
| Restic backup path mismatch | Rename directory on storage OR keep old path temporarily |
| CI build fails on new name | Include build.yml in atomic commit |
| SSH known hosts mismatch | common.nix update changes the key name but not the key value |

## Implementation Phases

### Phase 1: External -- Tailscale Node Rename

**Pre-requisite, run via SSH to the target machine.**

```bash
ssh cloud.bat-boa.ts.net sudo tailscale set --hostname=basestar
# Wait for MagicDNS propagation, then verify:
ping basestar.bat-boa.ts.net
```

- [ ] Tailscale node renamed to `basestar` via SSH
- [ ] `basestar.bat-boa.ts.net` resolves

### Phase 2: Secrets Infrastructure

Update `.sops.yaml` first (must happen before renaming the sops file).

**`.sops.yaml`** -- 5 changes:

| Line | Change |
|------|--------|
| 6 | `&host_cloud` → `&host_basestar` (same age key value) |
| 17 | `path_regex: secrets/sops/cloud\.yaml$` → `basestar\.yaml$` |
| 21 | `*host_cloud` → `*host_basestar` |
| 45 | `*host_cloud` → `*host_basestar` |
| 63 | `*host_cloud` → `*host_basestar` |

Then rename the secrets file:

```bash
git mv secrets/sops/cloud.yaml secrets/sops/basestar.yaml
```

Run updatekeys on files that reference the renamed anchor:

```bash
nix develop -c sops updatekeys secrets/sops/common.yaml
nix develop -c sops updatekeys secrets/sops/ntfy-client.yaml
```

### Phase 3: Host Directory Rename

```bash
git mv hosts/cloud hosts/basestar
```

This is the primary mechanism -- `flake-modules/hosts.nix` auto-discovers hosts by scanning `hosts/` directories.

### Phase 4: File Content Updates

#### Build-critical (deployment will fail without these)

**`hosts/basestar/configuration.nix`**:
- Line 111: `networking.hostName = "cloud"` → `"basestar"`

**`hosts/basestar/backup.nix`**:
- Line 14: profile name `cloud = {` → `basestar = {`
- Line 30: `repository = "rest:https://restic.arsfeld.one/cloud"` → `rest:https://restic.arsfeld.one/basestar`

**`modules/constellation/common.nix`** -- 3 changes:
- Line 59: `config.networking.hostName != "cloud"` → `!= "basestar"`
- Line 61: `hostName = "cloud.bat-boa.ts.net"` → `"basestar.bat-boa.ts.net"`
- Line 102: `"cloud.bat-boa.ts.net" = {` → `"basestar.bat-boa.ts.net" = {`

**`nix-builders.conf`**:
- Line 8: comment `# cloud is used` → `# basestar is used`
- Line 9: `ssh://root@cloud.bat-boa.ts.net` → `ssh://root@basestar.bat-boa.ts.net`

**`home/home.nix`**:
- Line 152: `osConfig.networking.hostName != "cloud"` → `!= "basestar"`
- Line 153: comment `# skip on cloud` → `# skip on basestar`

**`flake-modules/deploy.nix`**:
- Line 15: `hostName == "cloud"` → `hostName == "basestar"`, comment updated

**`.github/workflows/build.yml`**:
- Line 24: `host: cloud` → `host: basestar`

#### Service files in host directory

**`hosts/basestar/services/development.nix`**:
- Line 14: commented `"cloud"` in extraLabels → `"basestar"`
- Line 21: `instances.cloud` → `instances.basestar`
- Line 23: `name = "cloud"` → `name = "basestar"`

**`hosts/basestar/services/gatus.nix`**:
- Line 64: `cloudServiceNames` → `basestarServiceNames`
- Line 80: `cloudEndpoints` → `basestarEndpoints`
- Line 84: `group = "cloud"` → `group = "basestar"`
- Line 86: `cloudServiceNames` → `basestarServiceNames`

**`hosts/basestar/services.nix`**:
- Line 14-15: comments referencing "cloud services" → "basestar services"

#### Documentation

| File | Change |
|------|--------|
| `CLAUDE.md:7` | `(storage, cloud)` → `(storage, basestar)` |
| `CLAUDE.md:21` | `just deploy storage cloud` → `just deploy storage basestar` |
| `CLAUDE.md:44` | `secrets/sops/cloud.yaml` → `secrets/sops/basestar.yaml` |
| `CLAUDE.md:52` | `**cloud** - Cloud server` → `**basestar** - Public-facing server (BSG Cylon Basestar)` |
| `CLAUDE.md:107` | `not available on cloud` → `not available on basestar` |
| `CLAUDE.md:118` | `cloud vs storage` → `basestar vs storage` |
| `CLAUDE.md:135` | `hosted on **cloud**` → `hosted on **basestar**` |
| `CLAUDE.md:139` | `` `cloud` (aarch64-linux) serves as remote builder `` → `basestar` |
| `CLAUDE.md:159-160` | `on cloud` / `hosts/cloud/services/` → `on basestar` / `hosts/basestar/services/` |
| `CLAUDE.md:173` | scope `cloud` → `basestar` |
| `CLAUDE.md:179` | `Builds cloud (aarch64)` → `Builds basestar (aarch64)` |
| `README.md:15` | `**cloud**` row → `**basestar**` |
| `README.md:44` | `via cloud host` → `via basestar host` |
| `README.md:56` | `just deploy storage cloud` → `just deploy storage basestar` |
| `HARDWARE.md:22-29` | `### cloud` section → `### basestar` |
| `mkdocs.yml:97` | `Cloud Server: hosts/cloud.md` → `Basestar Server: hosts/basestar.md` |
| `docs/hosts/cloud.md` | `git mv docs/hosts/cloud.md docs/hosts/basestar.md` + update content |
| `docs/bsg-hostnames.md:9` | Mark cloud→basestar as completed (strikethrough + **bold**) |

#### NOT changed (historical records)

- `docs/plans/*.md` -- historical plans referencing cloud
- `docs/brainstorms/*.md` -- historical brainstorms
- `docs/architecture/*.md` -- architecture docs (can update later in a separate pass)
- `docs/guides/*.md` -- guides referencing cloud
- `blog/` -- blog posts are published content
- `hosts/basestar/services/rustdesk-README.md` -- internal README

### Phase 5: Build Verification

```bash
# All three hosts that reference remote builders must build successfully
nix build .#nixosConfigurations.basestar.config.system.build.toplevel
nix build .#nixosConfigurations.storage.config.system.build.toplevel
nix build .#nixosConfigurations.raider.config.system.build.toplevel

# No stale references in functional code
grep -r '"cloud"' hosts/ modules/ .sops.yaml flake-modules/ home/ nix-builders.conf
# Expected: zero matches (or only in commented-out code / non-hostname contexts)
```

### Phase 6: Restic Path Rename on Storage

Before deploying, rename the restic data directory on storage so the backup URL resolves:

```bash
ssh storage.bat-boa.ts.net sudo mv /var/data/restic-data/cloud /var/data/restic-data/basestar
```

If the path doesn't exist yet or is different, check with:
```bash
ssh storage.bat-boa.ts.net ls /var/data/restic-data/
```

### Phase 7: Commit & Deploy

```bash
# Single atomic commit
git add -A && git commit -m "refactor(hosts): rename cloud to basestar (BSG hostname scheme)"

# Deploy basestar first (it doesn't use remote builders, so no circular dependency)
just deploy basestar

# Then storage (if backup path was renamed)
just deploy storage

# Optionally redeploy raider/g14 to pick up new builder hostname
# (they'll fall back gracefully if builder is unreachable)
```

## Post-Deploy Verification

```bash
# Verify basestar hostname and services
ssh basestar.bat-boa.ts.net hostnamectl
ssh basestar.bat-boa.ts.net systemctl status caddy

# Verify arsfeld.dev services still work
curl -sI https://blog.arsfeld.dev | head -1
curl -sI https://plausible.arsfeld.dev | head -1

# Verify remote builder works from raider
ssh raider.bat-boa.ts.net nix build --eval --expr '"hello"' --builders 'ssh://root@basestar.bat-boa.ts.net aarch64-linux'

# Verify backup config
ssh basestar.bat-boa.ts.net systemctl list-timers 'restic-backups-basestar*'
```

- [ ] `hostnamectl` on basestar shows `basestar`
- [ ] `blog.arsfeld.dev` accessible
- [ ] `plausible.arsfeld.dev` accessible
- [ ] `planka.arsfeld.dev` accessible
- [ ] `siyuan.arsfeld.dev` accessible
- [ ] Remote builder accessible from other hosts
- [ ] Restic backup timer scheduled on basestar

## Sources & References

- BSG hostname scheme: `docs/bsg-hostnames.md`
- Completed cottage→pegasus rename: `docs/plans/2026-04-16-refactor-rename-cottage-to-pegasus-plan.md`
- Host auto-discovery: `flake-modules/hosts.nix`
- Sops module: `modules/constellation/sops.nix`
- Colmena dynamic targetHost: `flake-modules/colmena.nix`
- Remote builder config: `modules/constellation/common.nix:59-70`, `nix-builders.conf`
- Home-manager builder exclusion: `home/home.nix:152`
- Deploy-rs remote build: `flake-modules/deploy.nix:15`
- CI build matrix: `.github/workflows/build.yml:24`
