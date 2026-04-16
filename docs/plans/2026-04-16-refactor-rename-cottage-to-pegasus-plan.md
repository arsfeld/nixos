---
title: "Rename host cottage to pegasus"
type: refactor
status: completed
date: 2026-04-16
---

# Rename host cottage to pegasus

## Overview

Rename the NixOS host `cottage` to `pegasus` as the first step of the BSG hostname scheme defined in `docs/bsg-hostnames.md`. Pegasus is "The old Galactica hardware -- returned from retirement, still a battlestar."

This is a mechanical rename touching ~22 files. No behavior changes, no architectural changes -- just consistent naming.

## Problem Statement / Motivation

The BSG hostname scheme standardizes machine names around Battlestar Galactica ships. `cottage` is queued first because it's a secondary server with low traffic, making it low-risk for validating the rename process.

## Proposed Solution

Single atomic commit with all Nix source changes, coordinated with an external Tailscale node rename. Deploy pegasus first, then storage (which references pegasus in backup configs).

## Technical Considerations

### sops defaultSopsFile path

`modules/constellation/sops.nix:80` sets `defaultSopsFile = "${self}/secrets/sops/${hostname}.yaml"` whenever `constellation.sops.enable = true`. After rename, this resolves to `secrets/sops/pegasus.yaml`. Currently **no secret** uses the default (both `ntfy-publisher-env` and the backup `restic-password` set explicit `sopsFile`), but sops-nix may evaluate the path at build time. To be safe: create an empty `secrets/sops/pegasus.yaml`.

### Tailscale MagicDNS ordering

Colmena derives `targetHost = "${hostName}.bat-boa.ts.net"` dynamically. After directory rename, `just deploy pegasus` connects to `pegasus.bat-boa.ts.net`. This DNS name must exist **before** attempting deployment. The Tailscale node rename is external and must happen first.

### Backup transition window

Between Tailscale rename (cottage.bat-boa.ts.net stops resolving) and storage redeployment (backup URLs updated to pegasus), any backup timer firing on storage will fail. This window should be kept short. Acceptable: one missed weekly backup cycle.

### sops anchor rename is cosmetic

The `.sops.yaml` anchor `&host_cottage` changes to `&host_pegasus` but the age key value (derived from machine's SSH host key) stays identical. Run `sops updatekeys` on `common.yaml` and `ntfy-client.yaml` afterward to keep metadata consistent.

## Acceptance Criteria

- [x] `nix build .#nixosConfigurations.pegasus.config.system.build.toplevel` succeeds
- [x] `nix build .#nixosConfigurations.storage.config.system.build.toplevel` succeeds
- [x] `grep -r cottage hosts/ modules/ .sops.yaml` returns zero matches
- [x] `pegasus.bat-boa.ts.net` resolves via Tailscale MagicDNS
- [x] `just deploy pegasus` succeeds; `hostnamectl` on target shows `pegasus`
- [x] `just deploy storage` succeeds
- [x] `restic-backups-pegasus*` timers scheduled on storage

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Tailscale rename not propagated before deploy | Verify with `ping pegasus.bat-boa.ts.net` before deploying |
| Missing `secrets/sops/pegasus.yaml` breaks build | Create empty encrypted file before committing |
| Backup fails during transition window | Accept one missed cycle; manually trigger after both deploys |
| Old `cottage.bat-boa.ts.net` cached in DNS | Tailscale MagicDNS updates are fast; fallback: wait 5 min |

## Implementation Phases

### Phase 1: External -- Tailscale Node Rename

**Pre-requisite, run via SSH to the target machine.**

```bash
ssh cottage.bat-boa.ts.net sudo tailscale set --hostname=pegasus
# Wait for MagicDNS propagation, then verify:
ping pegasus.bat-boa.ts.net
```

- [x] Tailscale node renamed to `pegasus` via SSH
- [x] `pegasus.bat-boa.ts.net` resolves

### Phase 2: Secrets Infrastructure

Update `.sops.yaml` first (must happen before creating the sops file).

**`.sops.yaml`** -- 5 changes:

| Line | Change |
|------|--------|
| 12 | `&host_cottage` -> `&host_pegasus` (same age key value) |
| 35 | `path_regex: secrets/sops/cottage\.yaml$` -> `pegasus\.yaml$` |
| 39 | `*host_cottage` -> `*host_pegasus` |
| 51 | `*host_cottage` -> `*host_pegasus` |
| 67 | `*host_cottage` -> `*host_pegasus` |

Then create the empty secrets file:

```bash
nix develop -c sops secrets/sops/pegasus.yaml
# Save immediately with empty content -- sops will encrypt it with the correct keys
```

Run updatekeys on files that reference the renamed anchor:

```bash
nix develop -c sops updatekeys secrets/sops/common.yaml
nix develop -c sops updatekeys secrets/sops/ntfy-client.yaml
```

### Phase 3: Host Directory Rename

```bash
git mv hosts/cottage hosts/pegasus
```

This is the primary mechanism -- `flake-modules/hosts.nix` auto-discovers hosts by scanning `hosts/` directories.

### Phase 4: File Content Updates

#### Build-critical (deployment will fail without these)

**`hosts/pegasus/configuration.nix`**:
- Line 61: `networking.hostName = "cottage"` -> `"pegasus"`

**`hosts/storage/backup/backup-restic.nix`** -- 8 occurrences:

| Lines | Change |
|-------|--------|
| 7-8 | Comments: `cottage-system` / `cottage` -> `pegasus-system` / `pegasus` |
| 179 | Profile name: `cottage-system` -> `pegasus-system` |
| 182 | URL: `cottage.bat-boa.ts.net` -> `pegasus.bat-boa.ts.net` |
| 185 | Profile name: `cottage` -> `pegasus` |
| 188 | URL: `cottage.bat-boa.ts.net` -> `pegasus.bat-boa.ts.net` |
| 203 | Service: `restic-backups-cottage` -> `restic-backups-pegasus` |
| 204 | Service: `restic-backups-cottage-system` -> `restic-backups-pegasus-system` |

#### Cosmetic -- comments in host directory files

| File | Change |
|------|--------|
| `hosts/pegasus/configuration.nix:35` | Comment: "cottage must boot" -> "pegasus must boot" |
| `hosts/pegasus/configuration.nix:52` | Comment: "cottage-specific" -> "pegasus-specific" |
| `hosts/pegasus/disko-config.nix:1` | Comment header |
| `hosts/pegasus/hardware-configuration.nix:1` | Comment header |
| `hosts/pegasus/services/plex.nix:1` | Comment header |

#### Install scripts (update HOST_NAME, leave historical log messages)

| File | Key change |
|------|-----------|
| `hosts/pegasus/install-nixos.sh` | `HOST_NAME="cottage"` -> `"pegasus"` + embedded `hostName` |
| `hosts/pegasus/install-nixos-simple.sh` | `HOST_NAME="cottage"` -> `"pegasus"` + embedded `hostName` |
| `hosts/pegasus/prepare-for-infect.sh` | Echo messages |

#### Documentation

| File | Change |
|------|--------|
| `CLAUDE.md:58` | Host list: "cottage - Cottage system" -> "pegasus - Pegasus (BSG Battlestar)" |
| `README.md` | Host table row |
| `HARDWARE.md` | Hardware specs row |
| `docs/hosts/cottage.md` | `git mv docs/hosts/cottage.md docs/hosts/pegasus.md` + update content |
| `docs/tailscale-installation.md` | Example commands using cottage.bat-boa.ts.net |
| `docs/multi-domain-support.md` | Code examples and config snippets |
| `docs/architecture/backup.md` | Architecture description |
| `docs/bsg-hostnames.md` | Mark cottage->pegasus as completed |
| `secrets.md` | Legacy `restic-cottage-minio.age` references |
| `justfile:230,446` | Example commands |

#### NOT changed (historical records)

- `docs/plans/2026-04-15-feat-cottage-restic-rest-server-data-pool-plan.md`
- `docs/plans/2026-04-15-feat-secure-local-ntfy-plan.md`
- `docs/plans/2026-04-08-refactor-replace-tsnsrv-with-tailscale-services-plan.md`
- `docs/plans/2026-03-20-refactor-migrate-all-secrets-to-sops-plan.md`
- `docs/brainstorms/2026-04-15-cottage-restic-rest-target-brainstorm.md`
- `hosts/pegasus/NIXOS_INFECT_NOTES.md` (historical install notes)

### Phase 5: Build Verification

```bash
# Both hosts must build successfully
nix build .#nixosConfigurations.pegasus.config.system.build.toplevel
nix build .#nixosConfigurations.storage.config.system.build.toplevel

# No stale references in functional code
grep -r cottage hosts/ modules/ .sops.yaml
# Expected: zero matches
```

### Phase 6: Commit & Deploy

```bash
# Single atomic commit
git add -A && git commit -m "refactor(hosts): rename cottage to pegasus (BSG hostname scheme)"

# Deploy pegasus first (its hostname must match Tailscale)
just deploy pegasus

# Then storage (backup URLs now point to pegasus.bat-boa.ts.net)
just deploy storage
```

## Post-Deploy Verification

All verification commands run via SSH to the respective hosts:

```bash
# Verify pegasus hostname and services
ssh pegasus.bat-boa.ts.net hostnamectl
ssh pegasus.bat-boa.ts.net systemctl status restic-rest-server

# Verify storage backup timers point to pegasus
ssh storage.bat-boa.ts.net systemctl list-timers 'restic-backups-pegasus*'

# Trigger a test backup to verify connectivity
ssh storage.bat-boa.ts.net sudo systemctl start restic-backups-pegasus.service
```

- [ ] `hostnamectl` on pegasus shows `pegasus`
- [ ] `systemctl status restic-rest-server` on pegasus is active
- [ ] `restic-backups-pegasus*` timers are scheduled on storage
- [ ] Plex accessible at `pegasus.bat-boa.ts.net:32400`
- [ ] `sops --decrypt secrets/sops/common.yaml` works (validates key consistency)

## Sources & References

- BSG hostname scheme: `docs/bsg-hostnames.md`
- Host auto-discovery: `flake-modules/hosts.nix:8-18`
- Sops module: `modules/constellation/sops.nix:80`
- Colmena dynamic targetHost: `flake-modules/colmena.nix`
- Storage backup profiles: `hosts/storage/backup/backup-restic.nix:179-204`
